# Operating Model — Azure AI Foundry (v2)

> **Last updated:** April 2026  
> **Terraform providers:** `azurerm` + `azapi` (Azure/azapi)  
> **AVM Module:** `Azure/avm-ptn-aiml-ai-foundry/azurerm`  
> **Deployment modes:** Basic (Microsoft-managed state) | Standard (customer-managed state stores)

---

## Table of Contents

1. [Overview](#overview)
2. [Recommended Configuration](#recommended-configuration)
3. [High Availability (HA)](#high-availability-ha)
4. [Health Checks](#health-checks)
5. [Backup & Restore](#backup--restore)
6. [Monitoring & Alerting](#monitoring--alerting)
7. [Disaster Recovery (DR)](#disaster-recovery-dr)
8. [Terraform Examples](#terraform-examples)
9. [Reference Links](#reference-links)

---

## Overview

Microsoft Foundry (formerly Azure AI Foundry / Azure AI Studio) is the platform for building, deploying, and operating AI applications. It provisions **accounts**, **projects**, **model deployments**, **agent services**, and **connections** to external resources.

Key architectural points:
- **Platform infrastructure** (control plane, project metadata) is Microsoft-managed and regional.
- **State stores** (Cosmos DB, AI Search, Storage) are customer-managed in **Standard** deployment mode.
- **Optional resources** (Key Vault, ACR, App Insights, networking) are customer-managed.
- Foundry itself **does not provide automatic failover or disaster recovery**.

---

## Recommended Configuration

| Setting | Recommended Value | Notes |
|---|---|---|
| Deployment Mode | **Standard** | Customer-managed state stores; more recovery options |
| Managed Identity | **User-Assigned** | Survives resource recreation; avoids role reassignment |
| State Stores | Dedicated per workload | Azure Cosmos DB + AI Search + Storage Account |
| Resource Locks | `CanNotDelete` on account, Cosmos DB, AI Search, Storage | Prevent accidental deletion |
| denyAction Policy | Apply to critical resources | Layered protection with locks |
| Infrastructure as Code | Terraform / Bicep for all resources | Source of truth for reproducible deployments |
| Agent definitions | Version-controlled JSON + IaC pipeline | Rehydrate agents in recovery scenarios |
| Purview Connection | Enabled | Data continuity for compliance / eDiscovery |
| Networking | Private endpoints + VNet integration | Enterprise security posture |

---

## High Availability (HA)

### Platform Components

| Component | HA Responsibility | Configuration |
|---|---|---|
| Foundry control plane | Microsoft | Regional; zone-redundant (no customer action) |
| Project metadata | Microsoft | Regional |
| Azure Cosmos DB (agent state) | Customer | Zone redundancy + multi-region replication |
| Azure AI Search (agent indexes) | Customer | Zone redundancy (3 replicas minimum) |
| Azure Storage (attachments) | Customer | GZRS (geo-zone-redundant storage) |
| Azure Key Vault | Microsoft | Auto zone-redundant in supported regions |
| Application Insights | Customer | Consider multi-region instances |
| Azure Container Registry | Customer | Geo-replication (Premium SKU) |

### Zone Redundancy Checklist
All customer-managed state stores should use zone-redundant configurations:
- **Cosmos DB:** Availability zones enabled on account.
- **AI Search:** 3+ replicas for zone-redundant deployment.
- **Storage:** Zone-redundant storage (ZRS) or GZRS.

### Service Model & Shared Responsibility
- **Basic mode:** Microsoft manages data components; recovery options are limited.
- **Standard mode:** Customer owns state store durability; BCDR follows each underlying service's guidance.

---

## Health Checks

### Foundry Account Health
- **Azure Portal → Resource Health:** Check Foundry account status.
- **Service Health alerts:** Subscribe to `Microsoft.CognitiveServices` service health notifications.

### Model Deployment Health
- **Metrics:** Monitor model deployment availability, latency, and error rates via Azure Monitor.
- **HTTP health endpoint:** Model deployments expose inference endpoints; monitor HTTP 200 responses.

### Agent Service Health
- No dedicated health endpoint. Monitor via:
  - Cosmos DB request metrics (for agent state)
  - AI Search service metrics (for indexes)
  - Application Insights traces (for E2E flow)

### Infrastructure Health
```bash
# Check Foundry account
az cognitiveservices account show \
  --name <foundry-account> \
  --resource-group <rg> \
  --query "properties.provisioningState"

# Check model deployment
az cognitiveservices account deployment show \
  --name <foundry-account> \
  --resource-group <rg> \
  --deployment-name <deployment-name> \
  --query "properties.provisioningState"
```

---

## Backup & Restore

### Backup Strategy by Component

| Component | Backup Approach | Notes |
|---|---|---|
| **Foundry account/project config** | Infrastructure as Code (Terraform) | Redeploy from source control |
| **Model deployments** | IaC + deployment manifests | Redeploy models from IaC |
| **Agent definitions** | JSON in source control + pipeline API calls | Rehydrate via Foundry APIs |
| **Agent conversation threads** | Cosmos DB continuous backup (PITR) | Standard mode only |
| **Search indexes (agent knowledge)** | Rebuild from source data | AI Search has no native backup |
| **File attachments** | Azure Storage backup (GZRS + versioning) | Enable blob versioning & soft delete |
| **Connections** | IaC definitions | Secrets stored in Key Vault |
| **Key Vault secrets** | Key Vault soft-delete + purge protection | Auto-enabled; 90 day retention |

### Agent Conversation Recovery (Standard Mode)
```text
Thread history → Cosmos DB (enterprise_memory database)
                → AI Search indexes
                → Storage blobs (attachments)
```
- **Cosmos DB PITR:** Restore to any point within retention period.
- **AI Search:** No built-in restore; rebuild indexes from source.
- **Storage:** Use versioning or GZRS failover.
- **No built-in one-click export/import** for complete conversation histories.

### Key Recommendations
1. Store agent definitions, tool bindings, and knowledge source references in **source control**.
2. Use service APIs to periodically **snapshot** critical agent definitions.
3. Treat user-uploaded files in conversation threads as **transient** — they are lost in disaster.
4. Connect to **Microsoft Purview** for compliance continuity.

---

## Monitoring & Alerting

### Model Deployment Metrics (Azure Monitor)

| Metric | Description | Alert On |
|---|---|---|
| `TokenTransaction` | Total tokens processed | Quota limits |
| `ProcessedPromptTokens` | Input tokens consumed | Budget tracking |
| `GeneratedTokens` | Output tokens generated | Budget tracking |
| `SuccessfulCalls` | Successful API calls | Anomaly detection |
| `ClientErrors` | 4xx client errors | > threshold |
| `ServerErrors` | 5xx server errors | > 0 |
| `Latency` | Average response time | > SLA target |
| `ProvisionedManagedUtilizationV2` | PTU utilization (provisioned) | > 80% |
| `AzureOpenAIRequestsThrottled` | Throttled (429) requests | > 0 sustained |

### Diagnostic Settings
Route to Log Analytics:
- **RequestTrace** — Inference request/response traces
- **Audit** — Control plane operations
- **AllMetrics** — Platform metrics

### State Store Monitoring (Standard Mode)
- **Cosmos DB:** `TotalRequests`, `NormalizedRUConsumption`, `StatusCode 429`
- **AI Search:** `SearchLatency`, `ThrottledSearchQueriesPercentage`
- **Storage:** `Availability`, `E2ELatency`, `Transactions`

### Recommended Alert Rules

| Alert | Condition | Severity |
|---|---|---|
| Model 5xx errors | `ServerErrors > 0` for 5 min | Critical |
| Model 429 throttling | `AzureOpenAIRequestsThrottled > 10` in 5 min | Warning |
| High latency | `Latency > 10s` average for 15 min | Warning |
| Cosmos DB throttled | `StatusCode = 429` count > 0 | Warning |
| AI Search throttled | `ThrottledSearchQueriesPercentage > 5%` | Warning |
| Account deletion | Activity log: delete operation on Foundry account | Critical |

---

## Disaster Recovery (DR)

> **Foundry does not provide automatic failover or disaster recovery.** Recovery requires planning and customer action.

### DR Strategy: Warm Standby + IaC Reconstruction

#### Pre-Incident Preparation

| Action | Details |
|---|---|
| Define IaC templates | Terraform/Bicep for account, projects, capability host, dependencies |
| Store agent definitions in source control | JSON definitions, knowledge bindings, tool configs |
| Use user-assigned managed identities | Avoids role reassignment on recovery |
| Apply resource locks + denyAction policies | Prevent accidental deletion |
| Configure Cosmos DB multi-region | Enable read replication + Service-Managed Failover |
| Configure Storage GZRS | Customer-managed failover to secondary region |
| Enable Cosmos DB continuous backup | PITR for enterprise_memory database |

#### Recovery Procedures

| Scenario | Recovery Approach | Expected Outcome |
|---|---|---|
| **AZ failure** | Zone-redundant configs handle automatically | No customer action needed |
| **Region outage** | Redeploy Foundry account + projects in DR region; Cosmos DB failover; Storage failover; Rebuild AI Search indexes; Redeploy agents from source control | State partially recovered; threads may be incomplete |
| **Accidental account deletion** | Redeploy from IaC; reconnect BYOR resources; reattach managed identities | Config restored; data in state stores preserved |
| **Cosmos DB data loss** | PITR restore; update project connection strings | Thread data restored to point-in-time |
| **AI Search index loss** | Rebuild indexes from source data; re-index agent knowledge | Knowledge re-indexed; no built-in restore |
| **Agent definition loss** | Redeploy from source control via Foundry APIs | Agents recreated with new IDs; update client configs |

#### Single Responsibility Principle
- Dedicate Cosmos DB, AI Search, and Storage accounts **exclusively** to your Foundry workload.
- Do not share with other workloads to reduce blast radius.

---

## Terraform Examples

### AI Foundry Account + Project + Model Deployment + Monitoring

```hcl
# --- Providers ---
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = ">= 2.0"
    }
  }
}

# --- Variables ---
variable "location" {
  default = "eastus2"
}

variable "resource_group_name" {
  default = "rg-ai-foundry-prod"
}

# --- Resource Group ---
resource "azurerm_resource_group" "ai" {
  name     = var.resource_group_name
  location = var.location
}

# --- Log Analytics Workspace ---
resource "azurerm_log_analytics_workspace" "ai" {
  name                = "law-ai-foundry-prod"
  location            = azurerm_resource_group.ai.location
  resource_group_name = azurerm_resource_group.ai.name
  sku                 = "PerGB2018"
  retention_in_days   = 90
}

# --- User-Assigned Managed Identity ---
resource "azurerm_user_assigned_identity" "ai" {
  name                = "uami-ai-foundry"
  location            = azurerm_resource_group.ai.location
  resource_group_name = azurerm_resource_group.ai.name
}

# --- Key Vault ---
resource "azurerm_key_vault" "ai" {
  name                       = "kv-ai-foundry-prod"
  location                   = azurerm_resource_group.ai.location
  resource_group_name        = azurerm_resource_group.ai.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  purge_protection_enabled   = true
  soft_delete_retention_days = 90

  enable_rbac_authorization = true
}

# --- Storage Account (GZRS for DR) ---
resource "azurerm_storage_account" "ai" {
  name                     = "staifoundryprod"
  resource_group_name      = azurerm_resource_group.ai.name
  location                 = azurerm_resource_group.ai.location
  account_tier             = "Standard"
  account_replication_type = "GZRS"
  account_kind             = "StorageV2"

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }
  }

  tags = {
    environment = "production"
  }
}

# --- Foundry Account (using AzAPI for full control plane access) ---
resource "azapi_resource" "ai_foundry" {
  type      = "Microsoft.CognitiveServices/accounts@2024-10-01"
  name      = "ai-foundry-prod-contoso"
  location  = azurerm_resource_group.ai.location
  parent_id = azurerm_resource_group.ai.id

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.ai.id]
  }

  body = {
    kind = "AIServices"
    sku = {
      name = "S0"
    }
    properties = {
      customSubDomainName = "ai-foundry-prod-contoso"
      publicNetworkAccess = "Disabled"
      networkAcls = {
        defaultAction = "Deny"
      }
    }
  }

  tags = {
    environment = "production"
    managed_by  = "terraform"
  }
}

# --- Model Deployment ---
resource "azapi_resource" "gpt4o_deployment" {
  type      = "Microsoft.CognitiveServices/accounts/deployments@2024-10-01"
  name      = "gpt-4o"
  parent_id = azapi_resource.ai_foundry.id

  body = {
    sku = {
      name     = "Standard"
      capacity = 30 # TPM in thousands
    }
    properties = {
      model = {
        format  = "OpenAI"
        name    = "gpt-4o"
        version = "2024-08-06"
      }
    }
  }
}

# --- Foundry Project ---
resource "azapi_resource" "ai_project" {
  type      = "Microsoft.CognitiveServices/accounts/projects@2024-10-01"
  name      = "project-prod"
  parent_id = azapi_resource.ai_foundry.id
  location  = azurerm_resource_group.ai.location

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.ai.id]
  }

  body = {
    kind = "Project"
    sku = {
      name = "S0"
    }
    properties = {}
  }
}

# --- Resource Locks ---
resource "azurerm_management_lock" "ai_foundry_lock" {
  name       = "foundry-delete-lock"
  scope      = azapi_resource.ai_foundry.id
  lock_level = "CanNotDelete"
  notes      = "Prevent accidental deletion of AI Foundry account"
}

resource "azurerm_management_lock" "storage_lock" {
  name       = "storage-delete-lock"
  scope      = azurerm_storage_account.ai.id
  lock_level = "CanNotDelete"
  notes      = "Prevent accidental deletion of AI Foundry storage"
}

# --- Diagnostic Settings ---
resource "azurerm_monitor_diagnostic_setting" "ai_foundry" {
  name                       = "ai-foundry-diag"
  target_resource_id         = azapi_resource.ai_foundry.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.ai.id

  enabled_log {
    category = "RequestTrace"
  }

  enabled_log {
    category = "Audit"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

# --- Alert: Model Server Errors ---
resource "azurerm_monitor_metric_alert" "ai_server_errors" {
  name                = "ai-foundry-server-errors"
  resource_group_name = azurerm_resource_group.ai.name
  scopes              = [azapi_resource.ai_foundry.id]
  description         = "Alert on model deployment 5xx errors"
  severity            = 0
  frequency           = "PT5M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.CognitiveServices/accounts"
    metric_name      = "ServerErrors"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 0
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}

# --- Alert: Request Throttling ---
resource "azurerm_monitor_metric_alert" "ai_throttling" {
  name                = "ai-foundry-throttling"
  resource_group_name = azurerm_resource_group.ai.name
  scopes              = [azapi_resource.ai_foundry.id]
  description         = "Alert on sustained 429 throttling"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.CognitiveServices/accounts"
    metric_name      = "ClientErrors"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 50

    dimension {
      name     = "StatusCode"
      operator = "Include"
      values   = ["429"]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}

# --- Action Group ---
resource "azurerm_monitor_action_group" "ops" {
  name                = "ag-ops-team"
  resource_group_name = azurerm_resource_group.ai.name
  short_name          = "ops"

  email_receiver {
    name          = "ops-email"
    email_address = "ops@contoso.com"
  }
}

# --- Data Sources ---
data "azurerm_client_config" "current" {}
```

### Using the AVM Pattern Module (Recommended for Enterprise)

```hcl
module "ai_foundry" {
  source  = "Azure/avm-ptn-aiml-ai-foundry/azurerm"
  version = ">= 0.1.0"

  location            = "eastus2"
  resource_group_name = azurerm_resource_group.ai.name

  ai_foundry_name = "ai-foundry-prod"

  # BYOR (Bring Your Own Resource) — use dedicated resources
  key_vault_id       = azurerm_key_vault.ai.id
  storage_account_id = azurerm_storage_account.ai.id

  # Projects
  projects = {
    prod = {
      name = "project-prod"
    }
  }

  # Model deployments
  model_deployments = {
    gpt4o = {
      model_name    = "gpt-4o"
      model_version = "2024-08-06"
      model_format  = "OpenAI"
      sku_name      = "Standard"
      sku_capacity  = 30
    }
  }

  # Diagnostic settings
  diagnostic_settings = {
    main = {
      workspace_resource_id = azurerm_log_analytics_workspace.ai.id
      log_groups            = ["allLogs", "audit"]
      metric_categories     = ["AllMetrics"]
    }
  }

  # Locks
  lock = {
    kind = "CanNotDelete"
    name = "foundry-lock"
  }

  tags = {
    environment = "production"
    managed_by  = "terraform"
  }
}
```

---

## Reference Links

| Topic | Link |
|---|---|
| Microsoft Foundry Overview | https://learn.microsoft.com/azure/foundry/what-is-foundry |
| HA & Resiliency for Foundry | https://learn.microsoft.com/azure/foundry/how-to/high-availability-resiliency |
| Agent Service Disaster Recovery | https://learn.microsoft.com/azure/foundry/how-to/agent-service-disaster-recovery |
| Platform Outage Recovery | https://learn.microsoft.com/azure/foundry/how-to/agent-service-platform-disaster-recovery |
| Operator (Data Loss) Recovery | https://learn.microsoft.com/azure/foundry/how-to/agent-service-operator-disaster-recovery |
| Terraform for Foundry | https://learn.microsoft.com/azure/foundry/how-to/create-resource-terraform |
| AVM Pattern Module (Foundry) | https://registry.terraform.io/modules/Azure/avm-ptn-aiml-ai-foundry/azurerm/latest |
| AVM Cognitive Services Module | https://registry.terraform.io/modules/Azure/avm-res-cognitiveservices-account/azurerm/latest |
| Foundry Terraform Samples | https://github.com/azure-ai-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-terraform |
| Monitor Model Deployments | https://learn.microsoft.com/azure/foundry/foundry-models/how-to/monitor-models |
| RBAC for Foundry | https://learn.microsoft.com/azure/foundry/concepts/rbac-foundry |
| Standard Agent Setup | https://learn.microsoft.com/azure/ai-foundry/agents/concepts/standard-agent-setup |
| Foundry REST API Reference | https://learn.microsoft.com/rest/api/aifoundry/ |
