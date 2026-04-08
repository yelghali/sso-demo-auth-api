# Operating Model — Azure Container Registry (ACR)

> **Last updated:** April 2026  
> **Terraform provider:** `azurerm` (hashicorp/azurerm)  
> **Recommended SKU:** Premium (required for geo-replication, zone redundancy, private endpoints)

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

Azure Container Registry (ACR) is a managed Docker registry for storing and managing container images and OCI artifacts. The **Premium** tier is recommended for production workloads, providing geo-replication, zone redundancy, private endpoints, content trust, and customer-managed key encryption.

---

## Recommended Configuration

| Setting | Recommended Value | Notes |
|---|---|---|
| SKU | `Premium` | Required for geo-replication, zone redundancy, private endpoints |
| Zone Redundancy | `Enabled` | Automatically distributes replicas across AZs |
| Geo-Replication | ≥ 2 regions | Co-locate with consuming compute; enables DR |
| Admin Account | `Disabled` | Use Entra ID / managed identity authentication |
| Public Network Access | `Disabled` or restricted | Use private endpoints for production |
| Encryption | Customer-managed key (CMK) | Optional; for compliance requirements |
| Soft Delete | `Enabled` | 7–90 day retention for deleted artifacts |
| Retention Policy | `Enabled` | Auto-purge untagged manifests |
| Image Locking | Per-tag/manifest | Prevent accidental overwrites of production images |
| Resource Lock | `CanNotDelete` | Prevent accidental registry deletion |

---

## High Availability (HA)

### Zone Redundancy
- Enabled by default in Premium SKU in supported regions.
- Replicates registry data across a minimum of **3 availability zones** within a region.
- Protects against single-zone failures.

### Geo-Replication
- Distribute the registry across **multiple Azure regions**.
- Azure Traffic Manager routes requests to the nearest healthy replica.
- Pushes and pulls continue working even if one region experiences an outage.
- Storage limits are shared across all replicas; each replica incurs its own storage cost.

### Home Region Outage Behavior
- **Continues to work:** Image push/pull, authentication, webhook delivery from healthy replicas.
- **Unavailable:** Registry configuration changes, ACR Tasks (bound to home region).

### SLA
- Premium with geo-replication: up to **99.95%** availability per replica.

---

## Health Checks

### CLI Health Check
```bash
az acr check-health --name <registry-name> --yes
```
Checks: Docker daemon, CLI version, DNS resolution, registry login, network connectivity.

### Resource Health (Portal)
- Navigate to **Registry → Help → Resource Health**.
- Shows current and historical availability status.

### Webhook Health
- Configure webhooks for `push`, `delete`, `quarantine` events.
- Monitor webhook delivery failures via registry diagnostic logs.

### Automated Health Probe (Example)
```bash
# Pull a lightweight image as a health check
docker pull <registry-name>.azurecr.io/healthcheck:latest
```

---

## Backup & Restore

> ACR does **not** have a built-in point-in-time backup/restore feature. Redundancy and replication are the primary data protection mechanisms.

### Strategies

| Strategy | Method | Use Case |
|---|---|---|
| Geo-replication | Built-in (Premium) | Region-level protection |
| Image export | `az acr import` / `docker save` | Cross-registry copy, offline backup |
| ACR Transfer (air-gapped) | Import/export pipelines via Storage | Cross-tenant or air-gapped environments |
| Infrastructure as Code | Terraform / Bicep | Rebuild registry config in alternate region |

### Import Images (Cross-Registry Backup)
```bash
# Import from source registry to backup registry
az acr import \
  --name <backup-registry> \
  --source <source-registry>.azurecr.io/myapp:v1.0 \
  --image myapp:v1.0
```

### Docker-Based Backup
```bash
# Export
docker pull <registry>.azurecr.io/myapp:v1.0
docker save -o myapp-v1.0.tar <registry>.azurecr.io/myapp:v1.0

# Restore
docker load -i myapp-v1.0.tar
docker push <backup-registry>.azurecr.io/myapp:v1.0
```

---

## Monitoring & Alerting

### Key Metrics

| Metric | Description | Alert Threshold (Suggested) |
|---|---|---|
| `StorageUsed` | Total registry storage consumed | > 80% of tier limit |
| `SuccessfulPullCount` | Successful image pulls | Anomaly detection |
| `SuccessfulPushCount` | Successful image pushes | Anomaly detection |
| `TotalPullCount` | Total pull attempts (incl. failures) | Monitor for 401/403 spikes |
| `TotalPushCount` | Total push attempts | Monitor for 401/403 spikes |
| `AgentPoolCPUTime` | ACR Tasks agent pool CPU | > 80% utilization |

### Diagnostic Settings
Enable diagnostic settings to send logs to Log Analytics:
- **ContainerRegistryRepositoryEvents** — push, pull, delete, untag operations
- **ContainerRegistryLoginEvents** — authentication successes and failures

### Key Kusto Queries

```kusto
// Failed pull/push operations (4xx errors)
ContainerRegistryRepositoryEvents
| where ResultDescription contains "40"
| project TimeGenerated, OperationName, Repository, Tag, ResultDescription

// Authentication failures
ContainerRegistryLoginEvents
| where ResultDescription != "200"
| project TimeGenerated, Identity, CallerIpAddress, ResultDescription
```

### Recommended Alert Rules

| Alert | Condition | Severity |
|---|---|---|
| Storage usage high | `StorageUsed` > 5 GB (or custom) | Warning |
| Auth failure spike | `ContainerRegistryLoginEvents` where status != 200, count > 10 in 5 min | Critical |
| Pull failure spike | `ContainerRegistryRepositoryEvents` 4xx count > 5 in 5 min | Warning |

---

## Disaster Recovery (DR)

### Strategy: Active-Active with Geo-Replication

1. **Deploy Premium ACR** with geo-replication to ≥ 2 regions.
2. Traffic Manager automatically routes to the nearest healthy replica.
3. If one region fails, pushes/pulls continue via remaining replicas.
4. Home region recovery restores control plane operations.

### DR Testing
Simulate regional failover by temporarily disabling a geo-replica:
```bash
# Disable routing to a replica (simulates regional failure)
az acr replication update --registry <name> --location <region> --region-endpoint-enabled false

# Re-enable
az acr replication update --registry <name> --location <region> --region-endpoint-enabled true
```

### Recovery Procedures

| Scenario | Action |
|---|---|
| Single-zone failure | Zone redundancy handles automatically |
| Region failure (with geo-rep) | Traffic Manager routes to healthy replicas; no data loss |
| Region failure (no geo-rep) | Restore from backup registry or rebuild from IaC |
| Accidental image deletion | Restore from soft-delete (if enabled) or backup registry |
| Registry deletion | Restore from IaC + import images from backup |

---

## Terraform Examples

### Premium ACR with Geo-Replication, Zone Redundancy, and Monitoring

```hcl
# --- Variables ---
variable "location" {
  default = "eastus2"
}

variable "secondary_location" {
  default = "westus2"
}

variable "resource_group_name" {
  default = "rg-acr-prod"
}

# --- Resource Group ---
resource "azurerm_resource_group" "acr" {
  name     = var.resource_group_name
  location = var.location
}

# --- Log Analytics Workspace ---
resource "azurerm_log_analytics_workspace" "acr" {
  name                = "law-acr-prod"
  location            = azurerm_resource_group.acr.location
  resource_group_name = azurerm_resource_group.acr.name
  sku                 = "PerGB2018"
  retention_in_days   = 90
}

# --- Azure Container Registry (Premium) ---
resource "azurerm_container_registry" "main" {
  name                = "acrprodcontoso"
  resource_group_name = azurerm_resource_group.acr.name
  location            = azurerm_resource_group.acr.location
  sku                 = "Premium"
  admin_enabled       = false

  zone_redundancy_enabled       = true
  public_network_access_enabled = false
  data_endpoint_enabled         = true
  anonymous_pull_enabled        = false

  retention_policy_in_days = 30
  quarantine_policy_enabled  = true

  georeplications {
    location                = var.secondary_location
    zone_redundancy_enabled = true
    tags = {
      purpose = "disaster-recovery"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  tags = {
    environment = "production"
    managed_by  = "terraform"
  }
}

# --- Resource Lock ---
resource "azurerm_management_lock" "acr_lock" {
  name       = "acr-delete-lock"
  scope      = azurerm_container_registry.main.id
  lock_level = "CanNotDelete"
  notes      = "Prevent accidental deletion of production ACR"
}

# --- Diagnostic Settings ---
resource "azurerm_monitor_diagnostic_setting" "acr" {
  name                       = "acr-diag-loganalytics"
  target_resource_id         = azurerm_container_registry.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.acr.id

  enabled_log {
    category = "ContainerRegistryRepositoryEvents"
  }

  enabled_log {
    category = "ContainerRegistryLoginEvents"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

# --- Alert: Storage Usage ---
resource "azurerm_monitor_metric_alert" "acr_storage" {
  name                = "acr-storage-alert"
  resource_group_name = azurerm_resource_group.acr.name
  scopes              = [azurerm_container_registry.main.id]
  description         = "Alert when ACR storage exceeds threshold"
  severity            = 2
  frequency           = "PT15M"
  window_size         = "PT1H"

  criteria {
    metric_namespace = "Microsoft.ContainerRegistry/registries"
    metric_name      = "StorageUsed"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 5368709120 # 5 GB
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}

# --- Action Group (for alerts) ---
resource "azurerm_monitor_action_group" "ops" {
  name                = "ag-ops-team"
  resource_group_name = azurerm_resource_group.acr.name
  short_name          = "ops"

  email_receiver {
    name          = "ops-email"
    email_address = "ops@contoso.com"
  }
}

# --- Private Endpoint (optional) ---
resource "azurerm_private_endpoint" "acr" {
  name                = "pe-acr-prod"
  location            = azurerm_resource_group.acr.location
  resource_group_name = azurerm_resource_group.acr.name
  subnet_id           = var.subnet_id # Provide a subnet ID

  private_service_connection {
    name                           = "psc-acr"
    private_connection_resource_id = azurerm_container_registry.main.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }
}
```

---

## Reference Links

| Topic | Link |
|---|---|
| ACR Overview | https://learn.microsoft.com/azure/container-registry/container-registry-intro |
| Service Tiers (SKUs) | https://learn.microsoft.com/azure/container-registry/container-registry-skus |
| Reliability in ACR | https://learn.microsoft.com/azure/reliability/reliability-container-registry |
| Geo-Replication | https://learn.microsoft.com/azure/container-registry/container-registry-geo-replication |
| Zone Redundancy | https://learn.microsoft.com/azure/container-registry/zone-redundancy |
| Monitoring ACR | https://learn.microsoft.com/azure/container-registry/monitor-container-registry |
| Monitoring Data Reference | https://learn.microsoft.com/azure/container-registry/monitor-container-registry-reference |
| Image Locking | https://learn.microsoft.com/azure/container-registry/container-registry-image-lock |
| Soft Delete | https://learn.microsoft.com/azure/container-registry/container-registry-soft-delete-policy |
| Private Endpoints | https://learn.microsoft.com/azure/container-registry/container-registry-private-link |
| ACR Best Practices | https://learn.microsoft.com/azure/container-registry/container-registry-best-practices |
| Import Images | https://learn.microsoft.com/azure/container-registry/container-registry-import-images |
| ACR Health Check CLI | https://learn.microsoft.com/azure/container-registry/container-registry-check-health |
| Terraform `azurerm_container_registry` | https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/container_registry |
