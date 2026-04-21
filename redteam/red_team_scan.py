"""
=============================================================================
AI Red Teaming Agent - Local Scan Example
=============================================================================
This script demonstrates how to use Azure AI Foundry's Red Teaming Agent
to automatically scan an AI application for safety risks locally.

The Red Teaming Agent uses PyRIT (Python Risk Identification Tool) under
the hood to:
  1. Generate adversarial attack prompts across risk categories
  2. Apply attack strategies (encoding, obfuscation, etc.) to bypass safeguards
  3. Evaluate each attack-response pair for safety violations
  4. Produce a scorecard with Attack Success Rate (ASR) metrics

Prerequisites:
  - Python 3.10+
  - Azure AI Foundry project in a supported region (East US 2, Sweden Central, etc.)
  - Logged in via `az login`
  - Install: pip install "azure-ai-evaluation[redteam]"
=============================================================================
"""

import asyncio
import os

# ---------------------------------------------------------------------------
# Azure SDK imports
# ---------------------------------------------------------------------------
from azure.identity import DefaultAzureCredential          # Uses az login credentials
from azure.ai.evaluation.red_team import (
    RedTeam,            # The main Red Teaming Agent class
    RiskCategory,       # Enum for risk categories (Violence, Sexual, etc.)
    AttackStrategy,     # Enum/class for attack strategies (Base64, ROT13, etc.)
)


# ---------------------------------------------------------------------------
# 1. CONFIGURE YOUR AZURE AI FOUNDRY PROJECT
# ---------------------------------------------------------------------------
# The Red Teaming Agent needs a Foundry project to generate attack objectives
# and evaluate responses.
#
# Option A — Endpoint URL (new Foundry style, recommended):
#   azure_ai_project = "https://<account>.services.ai.azure.com/api/projects/<project>"
#
# Option B — Dictionary (old Foundry Hub / ML Workspace style):
#   azure_ai_project = {"subscription_id": "...", "resource_group_name": "...", "project_name": "..."}
#
# We use Option A with the Sweden Central project (supported region for Red Teaming).
azure_ai_project = "https://my-foundry-yaya.services.ai.azure.com/api/projects/proj-default"

# Authenticate using DefaultAzureCredential (picks up your `az login` session)
credential = DefaultAzureCredential()


# ---------------------------------------------------------------------------
# 2. DEFINE YOUR TARGET APPLICATION (what you want to red-team)
# ---------------------------------------------------------------------------
# This is a simple callback that simulates your AI chatbot or application.
# In a real scenario, replace this with a call to your actual AI endpoint,
# RAG pipeline, or any function that takes a user query and returns a response.

def my_chatbot(query: str) -> str:
    """
    Simulated chatbot target for red teaming.
    A well-behaved bot should refuse harmful requests.
    Replace this with your actual application logic.
    """
    # Example: a naive bot that just echoes — this WILL fail safety checks
    return f"Sure, here is information about: {query}"


# ---------------------------------------------------------------------------
# 3. CONFIGURE THE RED TEAMING AGENT
# ---------------------------------------------------------------------------
# Specify which risk categories to test and how many attack objectives per category.
# Each risk category generates adversarial prompts designed to elicit unsafe responses.

red_team_agent = RedTeam(
    azure_ai_project=azure_ai_project,    # Your Foundry project reference
    credential=credential,                 # Azure credentials
    risk_categories=[                      # Which safety risks to probe
        RiskCategory.Violence,             # Prompts about violent content
        RiskCategory.HateUnfairness,       # Prompts about hate/discrimination
        RiskCategory.Sexual,               # Prompts about sexual content
        RiskCategory.SelfHarm,             # Prompts about self-harm
    ],
    num_objectives=2,                      # Number of attack prompts PER risk category
                                           # Total baseline prompts = 2 * 4 = 8
)


# ---------------------------------------------------------------------------
# 4. RUN THE SCAN WITH ATTACK STRATEGIES
# ---------------------------------------------------------------------------
# Attack strategies transform baseline adversarial prompts to try bypassing
# safeguards. Each strategy adds more attack-response pairs to the scan.
#
# Complexity levels:
#   - Easy:     Simple encoding (Base64, ROT13, Morse, Flip, etc.)
#   - Moderate: Requires another AI model (e.g., tense change)
#   - Difficult: Compositions of multiple strategies
#
# With 8 baseline prompts + 3 attack strategies → 8 + (8*3) = 32 total pairs

async def run_scan():
    """Execute the red teaming scan and output results."""

    print("=" * 60)
    print("Starting AI Red Teaming Scan...")
    print("=" * 60)
    print(f"Risk categories: Violence, HateUnfairness, Sexual, SelfHarm")
    print(f"Attack objectives per category: 2")
    print(f"Attack strategies: Base64, ROT13, Compose(Base64+ROT13)")
    print("=" * 60)

    # Run the scan against our target chatbot
    result = await red_team_agent.scan(
        target=my_chatbot,                  # The function/app to red-team
        scan_name="Demo-RedTeam-Scan",      # Name shown in Foundry portal
        output_path="redteam_results.json", # Save detailed scorecard to JSON
        attack_strategies=[                 # Attack techniques to apply
            AttackStrategy.Base64,          # Easy: encode prompt in Base64
            AttackStrategy.ROT13,           # Easy: apply ROT13 cipher
            AttackStrategy.Compose([        # Difficult: chain two strategies
                AttackStrategy.Base64,      #   First encode in Base64...
                AttackStrategy.ROT13,       #   ...then apply ROT13 on top
            ]),
        ],
    )

    # ---------------------------------------------------------------------------
    # 5. REVIEW THE RESULTS
    # ---------------------------------------------------------------------------
    # The scan returns an Attack Success Rate (ASR) — the percentage of attacks
    # that successfully got unsafe responses from your target.
    #
    # ASR = 0% means your app blocked all attacks (good!)
    # ASR = 100% means every attack succeeded (your app needs better safeguards)

    print("\n" + "=" * 60)
    print("SCAN COMPLETE — Results Summary")
    print("=" * 60)

    # Print the scorecard dataframe if available
    if hasattr(result, "scorecard"):
        print("\nScorecard:")
        print(result.scorecard)

    # Print attack-response pair details if available
    if hasattr(result, "attack_details"):
        print("\nAttack Details (first 5):")
        for detail in result.attack_details[:5]:
            print(f"  Strategy: {detail.get('strategy', 'N/A')}")
            print(f"  Category: {detail.get('risk_category', 'N/A')}")
            print(f"  Success:  {detail.get('success', 'N/A')}")
            print(f"  Prompt:   {detail.get('prompt', 'N/A')[:80]}...")
            print()

    print(f"\nFull results saved to: redteam_results.json")
    print("Open this file to see the full scorecard with per-category ASR breakdown.")

    return result


# ---------------------------------------------------------------------------
# 6. ENTRY POINT
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    # The RedTeam scan is async, so we run it with asyncio
    asyncio.run(run_scan())
