# AI Red Teaming — Azure AI Foundry

Red teaming scripts to scan AI applications for safety risks using Azure AI Foundry and PyRIT.

## Scripts

| Script | Approach | Description |
|--------|----------|-------------|
| `red_team_scan.py` | **Local** | Runs PyRIT locally via `azure-ai-evaluation[redteam]`. Targets a callback function. **Fully working.** |
| `red_team_cloud.py` | **Cloud** | Runs server-side via `azure-ai-projects` Evals API. Targets a Foundry model deployment. **Preview — requires Foundry Agent target for full red teaming.** |

## Quick Start

```bash
# Login to Azure
az login

# Install dependencies
pip install "azure-ai-evaluation[redteam]"   # for local scan
pip install "azure-ai-projects>=2.0.0"       # for cloud scan

# Run local scan (uses a callback target)
python red_team_scan.py

# Run cloud scan (targets a model deployment)
python red_team_cloud.py
```

## Configuration

Both scripts use `my-foundry-yaya / proj-default` (Sweden Central) by default.  
Edit the `azure_ai_project` / `ENDPOINT` variable to point to your own project.

## Local Scan — How It Works

1. **RedTeam agent** generates adversarial prompts across risk categories (Violence, Hate, Sexual, Self-Harm)
2. **Attack strategies** (Base64, ROT13, Compose) transform prompts to bypass safeguards
3. Each prompt is sent to your **target callback** function
4. Responses are **evaluated** for safety violations
5. A **scorecard** with Attack Success Rate (ASR) is produced

## Cloud Scan — How It Works

1. Creates a **Red Team evaluation group** in Foundry with built-in evaluators
2. Creates a **run** with attack strategies targeting your model deployment
3. **Polls** server-side until the run completes
4. **Fetches results** and saves them locally

## Results

- `redteam_results.json` — Local scan scorecard with per-category ASR breakdown
- `cloud_results/` — Cloud scan output items

## Supported Regions

East US 2, France Central, Sweden Central, Switzerland West, US North Central
