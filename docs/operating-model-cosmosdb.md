# Operating Model — Azure Cosmos DB

> **Last updated:** April 2026  
> **Terraform provider:** `azurerm` (hashicorp/azurerm)  
> **AVM Module:** `Azure/avm-res-documentdb-databaseaccount/azurerm`  
> **APIs:** NoSQL, MongoDB, Cassandra, Gremlin, Table

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

Azure Cosmos DB is a globally distributed, multi-model database service with turnkey global distribution, elastic scaling of throughput and storage, single-digit millisecond latency, and five well-defined consistency levels. It provides SLAs up to **99.999%** for multi-write region accounts. Cosmos DB offers two backup modes (periodic and continuous) and supports multi-region replication with automatic or manual failover.

---

## Recommended Configuration

| Setting | Recommended Value | Notes |
|---|---|---|
| Replication | **Multi-region** (≥ 2 regions) | Required for HA and DR |
| Availability Zones | `Enabled` | Zone-redundant within each region |
| Consistency Level | Per workload (Session recommended) | Balance between consistency and performance |
| Backup Mode | **Continuous** | PITR with 1-second granularity; 7 or 30 day retention |
| Multi-Write Regions | Enable if write HA is critical | Enables writes in any region; conflict resolution needed |
| Per Partition Auto Failover (PPAF) | Enable (if available) | Partition-level failover for single-write accounts |
| Service-Managed Failover | `Enabled` | Automatic failover during regional outages |
| Throughput | Autoscale | Dynamic scaling; avoids over-provisioning |
| Networking | Private endpoints | Disable public network access |
| Encryption | CMK (optional) | For compliance requirements |
| Resource Lock | `CanNotDelete` | Prevent accidental deletion |

---

## High Availability (HA)

### Architecture Tiers

| Configuration | Write Availability | Read Availability | SLA |
|---|---|---|---|
| Single region, no AZ | Per region | Per region | 99.99% |
| Single region + AZ | Zone-redundant | Zone-redundant | 99.995% |
| Multi-region, single write | Write in 1 region | Read from any region | 99.999% (reads) |
| Multi-region, multi-write | Write in any region | Read from any region | 99.999% |

### Zone Redundancy
- When AZ is enabled, Cosmos DB spreads replicas across ≥ 3 availability zones.
- Protects against single-zone failures within a region.
- No impact on latency or throughput.

### Multi-Region Replication
- Data is replicated to all configured regions.
- SDK automatically routes to the nearest available region.
- For **single-write** accounts: reads can be served from any region; writes go to the write region.
- For **multi-write** accounts: both reads and writes served from any region.

### Automatic Failover
- **Service-Managed Failover:** Cosmos DB automatically fails over the write region during a sustained outage.
- **Per Partition Automatic Failover (PPAF):** Partition-level failover for granular resilience.
- **Manual Failover:** Customer-triggered for testing or planned migration.

### Conflict Resolution (Multi-Write)
- **Last Writer Wins (LWW):** Default; based on `_ts` property.
- **Custom:** User-defined stored procedure for merge logic.

---

## Health Checks

### Resource Health
- **Portal:** Cosmos DB account → Help → Resource Health.
- Shows current and historical availability status.
- Subscribe to **Service Health** alerts for `Microsoft.DocumentDB`.

### Metric-Based Health
```text
Monitor these metrics for availability:
- ServiceAvailability: Overall account availability (target: > 99.99%)
- TotalRequests + StatusCode dimension: Check for elevated 5xx or 429 responses
- ReplicationLatency: Cross-region replication lag
```

### Application-Level Health Check
```csharp
// .NET SDK health check
var client = new CosmosClient(endpoint, key);
var database = client.GetDatabase("mydb");
var response = await database.ReadAsync();
// HTTP 200 = healthy
```

```python
# Python SDK health check
from azure.cosmos import CosmosClient
client = CosmosClient(url=endpoint, credential=key)
database = client.get_database_client("mydb")
database.read()  # Raises exception if unhealthy
```

### CLI Health Check
```bash
# Check account status
az cosmosdb show \
  --name <account-name> \
  --resource-group <rg> \
  --query "properties.provisioningState"

# Check failover priority
az cosmosdb failover-priority-change show \
  --name <account-name> \
  --resource-group <rg>
```

---

## Backup & Restore

### Backup Modes

| Mode | Granularity | Retention | Restore Target | Cost |
|---|---|---|---|---|
| **Periodic** | Full snapshot every 4h (configurable) | 2 most recent (configurable up to 720h interval, 1–720 copies) | New account (contact support) | Included |
| **Continuous (7-day)** | Every 100 seconds per region | 7 days | New account (self-service) | Additional cost |
| **Continuous (30-day)** | Every 100 seconds per region | 30 days | New account (self-service) | Additional cost |

### Periodic Backup Details
- Full backup stored in Azure Blob Storage.
- Geo-redundant: snapshots replicated to the paired region via GRS.
- Restore requires Azure Support request.
- Cannot access backups directly.

### Continuous Backup (PITR)
- Backed up every **100 seconds** per region.
- Restore to **any point in time** with 1-second granularity.
- Self-service restore via Azure portal, CLI, or REST API.
- Restores to a **new account** (does not overwrite existing).

### Restore Procedures

```bash
# Continuous backup — point-in-time restore
az cosmosdb restore \
  --account-name <new-account-name> \
  --resource-group <rg> \
  --target-database-account-name <source-account> \
  --restore-timestamp "2026-04-08T10:00:00Z" \
  --location <region>

# Check restore status
az cosmosdb show \
  --name <new-account-name> \
  --resource-group <rg> \
  --query "properties.restoreParameters"
```

### Backup Best Practices
1. Use **Continuous 30-day** for production workloads.
2. Enable **multi-region** replication for data durability.
3. Implement **resource locks** to prevent accidental account deletion.
4. Periodically test restore procedures.
5. For periodic backup: customize interval and retention based on RPO.

---

## Monitoring & Alerting

### Key Metrics

| Metric | Description | Alert Threshold |
|---|---|---|
| `TotalRequests` | Total requests by status code | Filter 429/5xx |
| `NormalizedRUConsumption` | % of provisioned RU/s used | > 80% sustained |
| `TotalRequestUnits` | Total RUs consumed | Budget tracking |
| `ServerSideLatency` | Server-side latency (ms) | > P99 target |
| `ServiceAvailability` | Account availability % | < 99.99% |
| `ReplicationLatency` | Cross-region replication lag (ms) | > 1000ms |
| `DocumentCount` | Number of documents | Capacity planning |
| `DataUsage` | Storage consumed (bytes) | > 80% of partition limit |
| `IndexUsage` | Index storage consumed | Monitor growth |
| `ProvisionedThroughput` | Configured RU/s | N/A (informational) |
| `AutoscaleMaxThroughput` | Autoscale max RU/s | N/A (informational) |
| `RegionFailover` | Region failover events | Count > 0 |
| `MetadataRequests` | Metadata operations | Anomaly |

### Diagnostic Settings
Route to Log Analytics for deep analysis:
- **DataPlaneRequests** — CRUD operations
- **QueryRuntimeStatistics** — Query execution stats
- **PartitionKeyStatistics** — Hot partition detection
- **PartitionKeyRUConsumption** — RU consumption per partition key
- **ControlPlaneRequests** — Management operations

### Key Kusto Queries

```kusto
// Top 10 most expensive queries by RU consumption
CDBDataPlaneRequests
| where TimeGenerated > ago(24h)
| summarize TotalRU = sum(RequestCharge) by OperationName, DatabaseName, CollectionName
| top 10 by TotalRU desc

// 429 (throttled) requests over time
CDBDataPlaneRequests
| where StatusCode == 429
| summarize ThrottledCount = count() by bin(TimeGenerated, 5m)
| render timechart

// Cross-region replication latency
AzureMetrics
| where MetricName == "ReplicationLatency"
| summarize AvgLatency = avg(Average) by bin(TimeGenerated, 5m), Resource
| render timechart

// Storage approaching partition limit (20 GB)
CDBPartitionKeyStatistics
| where SizeKb > 15000000 // > 15 GB
| project TimeGenerated, DatabaseName, CollectionName, PartitionKey, SizeKb
```

### Recommended Alert Rules

| Alert | Condition | Severity |
|---|---|---|
| Rate limiting (429) | `TotalRequests` where StatusCode = 429, count > 0 | Warning (Sev 2) |
| Service unavailability | `ServiceAvailability < 99.99%` | Critical (Sev 0) |
| Region failover | `RegionFailover` count > 0 | Critical (Sev 1) |
| High RU consumption | `NormalizedRUConsumption > 80%` for 15 min | Warning (Sev 2) |
| High replication lag | `ReplicationLatency > 1000ms` | Warning (Sev 2) |
| Server-side latency | `ServerSideLatency P99 > 50ms` | Warning (Sev 2) |
| Key rotation | Activity log: keys accessed/rotated | Informational |
| Logical partition near 20 GB | Custom log query on partition stats | Warning (Sev 2) |

---

## Disaster Recovery (DR)

### Recovery Options by Account Configuration

| Configuration | Outage Scenario | Recovery |
|---|---|---|
| **Single-region** | Region outage | Wait for recovery; or request restore to different region |
| **Single-region + AZ** | AZ failure | Automatic; zone-redundant replicas |
| **Multi-region, single-write** | Read region outage | SDK routes to available regions automatically |
| **Multi-region, single-write** | Write region outage (PPAF) | Automatic partition-level failover |
| **Multi-region, single-write** | Write region outage (no PPAF) | Manual offline region operation; or wait for service-managed failover |
| **Multi-write** | Any region outage | Automatic; SDK routes to healthy regions |
| **Any** | Data corruption/accidental delete | PITR (continuous) or periodic backup restore |

### Failover Testing
```bash
# Trigger manual failover (test DR)
az cosmosdb failover-priority-change \
  --name <account-name> \
  --resource-group <rg> \
  --failover-policies "<dr-region>=0" "<primary-region>=1"

# Verify new write region
az cosmosdb show \
  --name <account-name> \
  --resource-group <rg> \
  --query "properties.writeLocations[0].locationName"
```

### DR Best Practices
1. **Multi-region accounts:** Configure ≥ 2 regions with service-managed failover enabled.
2. **Enable PPAF** for single-write accounts (partition-level failover).
3. **Use continuous backup** for self-service PITR.
4. **Test manual failover** quarterly.
5. **Monitor `ReplicationLatency`** to understand RPO in regional failure scenarios.
6. **Configure SDK** with `ApplicationPreferredRegions` for optimal failover routing.

---

## Terraform Examples

### Multi-Region Cosmos DB with Continuous Backup, Zone Redundancy, and Monitoring

```hcl
# --- Variables ---
variable "location" {
  default = "eastus2"
}

variable "secondary_location" {
  default = "westus2"
}

variable "resource_group_name" {
  default = "rg-cosmosdb-prod"
}

# --- Resource Group ---
resource "azurerm_resource_group" "cosmos" {
  name     = var.resource_group_name
  location = var.location
}

# --- Log Analytics Workspace ---
resource "azurerm_log_analytics_workspace" "cosmos" {
  name                = "law-cosmos-prod"
  location            = azurerm_resource_group.cosmos.location
  resource_group_name = azurerm_resource_group.cosmos.name
  sku                 = "PerGB2018"
  retention_in_days   = 90
}

# --- Cosmos DB Account ---
resource "azurerm_cosmosdb_account" "main" {
  name                = "cosmos-prod-contoso"
  location            = azurerm_resource_group.cosmos.location
  resource_group_name = azurerm_resource_group.cosmos.name
  offer_type          = "Standard"

  kind                       = "GlobalDocumentDB" # NoSQL API
  automatic_failover_enabled = true
  multiple_write_locations_enabled = false # Single-write; enable for multi-write

  # Consistency policy
  consistency_policy {
    consistency_level       = "Session"
    max_interval_in_seconds = 5
    max_staleness_prefix    = 100
  }

  # Primary region with AZ
  geo_location {
    location          = var.location
    failover_priority = 0
    zone_redundant    = true
  }

  # Secondary region with AZ
  geo_location {
    location          = var.secondary_location
    failover_priority = 1
    zone_redundant    = true
  }

  # Continuous backup (30-day PITR)
  backup {
    type                = "Continuous"
    tier                = "Continuous30Days"
    storage_redundancy  = "Geo"
  }

  # Networking
  public_network_access_enabled = false
  is_virtual_network_filter_enabled = true

  # Identity
  identity {
    type = "SystemAssigned"
  }

  tags = {
    environment = "production"
    managed_by  = "terraform"
  }
}

# --- SQL Database ---
resource "azurerm_cosmosdb_sql_database" "main" {
  name                = "appdb"
  resource_group_name = azurerm_resource_group.cosmos.name
  account_name        = azurerm_cosmosdb_account.main.name

  autoscale_settings {
    max_throughput = 4000
  }
}

# --- SQL Container ---
resource "azurerm_cosmosdb_sql_container" "orders" {
  name                = "orders"
  resource_group_name = azurerm_resource_group.cosmos.name
  account_name        = azurerm_cosmosdb_account.main.name
  database_name       = azurerm_cosmosdb_sql_database.main.name
  partition_key_paths = ["/customerId"]

  autoscale_settings {
    max_throughput = 4000
  }

  indexing_policy {
    indexing_mode = "consistent"

    included_path {
      path = "/*"
    }

    excluded_path {
      path = "/\"_etag\"/?"
    }
  }

  default_ttl = -1 # No expiry; set to seconds for TTL

  conflict_resolution_policy {
    mode                     = "LastWriterWins"
    conflict_resolution_path = "/_ts"
  }
}

# --- Resource Lock ---
resource "azurerm_management_lock" "cosmos_lock" {
  name       = "cosmos-delete-lock"
  scope      = azurerm_cosmosdb_account.main.id
  lock_level = "CanNotDelete"
  notes      = "Prevent accidental deletion of production Cosmos DB account"
}

# --- Private Endpoint ---
resource "azurerm_private_endpoint" "cosmos" {
  name                = "pe-cosmos-prod"
  location            = azurerm_resource_group.cosmos.location
  resource_group_name = azurerm_resource_group.cosmos.name
  subnet_id           = var.subnet_id

  private_service_connection {
    name                           = "psc-cosmos"
    private_connection_resource_id = azurerm_cosmosdb_account.main.id
    subresource_names              = ["Sql"] # Use "MongoDB", "Cassandra", etc. for other APIs
    is_manual_connection           = false
  }
}

# --- Diagnostic Settings ---
resource "azurerm_monitor_diagnostic_setting" "cosmos" {
  name                       = "cosmos-diag-loganalytics"
  target_resource_id         = azurerm_cosmosdb_account.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.cosmos.id

  enabled_log {
    category = "DataPlaneRequests"
  }

  enabled_log {
    category = "QueryRuntimeStatistics"
  }

  enabled_log {
    category = "PartitionKeyStatistics"
  }

  enabled_log {
    category = "PartitionKeyRUConsumption"
  }

  enabled_log {
    category = "ControlPlaneRequests"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

# --- Alert: Rate Limiting (429) ---
resource "azurerm_monitor_metric_alert" "cosmos_throttling" {
  name                = "cosmos-throttling-alert"
  resource_group_name = azurerm_resource_group.cosmos.name
  scopes              = [azurerm_cosmosdb_account.main.id]
  description         = "Alert when Cosmos DB requests are throttled"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.DocumentDB/databaseAccounts"
    metric_name      = "TotalRequests"
    aggregation      = "Count"
    operator         = "GreaterThan"
    threshold        = 0

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

# --- Alert: Service Availability ---
resource "azurerm_monitor_metric_alert" "cosmos_availability" {
  name                = "cosmos-availability-alert"
  resource_group_name = azurerm_resource_group.cosmos.name
  scopes              = [azurerm_cosmosdb_account.main.id]
  description         = "Alert when Cosmos DB availability drops"
  severity            = 0
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.DocumentDB/databaseAccounts"
    metric_name      = "ServiceAvailability"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 99.99
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}

# --- Alert: High Normalized RU Consumption ---
resource "azurerm_monitor_metric_alert" "cosmos_ru" {
  name                = "cosmos-high-ru-alert"
  resource_group_name = azurerm_resource_group.cosmos.name
  scopes              = [azurerm_cosmosdb_account.main.id]
  description         = "Alert when RU consumption exceeds 80%"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.DocumentDB/databaseAccounts"
    metric_name      = "NormalizedRUConsumption"
    aggregation      = "Maximum"
    operator         = "GreaterThan"
    threshold        = 80
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}

# --- Alert: Region Failover ---
resource "azurerm_monitor_activity_log_alert" "cosmos_failover" {
  name                = "cosmos-failover-alert"
  resource_group_name = azurerm_resource_group.cosmos.name
  scopes              = [azurerm_resource_group.cosmos.id]
  description         = "Alert when a Cosmos DB region fails over"

  criteria {
    resource_id    = azurerm_cosmosdb_account.main.id
    operation_name = "Microsoft.DocumentDB/databaseAccounts/failoverPriorityChange/action"
    category       = "Administrative"
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}

# --- Alert: High Replication Latency ---
resource "azurerm_monitor_metric_alert" "cosmos_replication_lag" {
  name                = "cosmos-replication-lag-alert"
  resource_group_name = azurerm_resource_group.cosmos.name
  scopes              = [azurerm_cosmosdb_account.main.id]
  description         = "Alert when cross-region replication latency is high"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.DocumentDB/databaseAccounts"
    metric_name      = "ReplicationLatency"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 1000 # 1 second
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}

# --- Action Group ---
resource "azurerm_monitor_action_group" "ops" {
  name                = "ag-ops-team"
  resource_group_name = azurerm_resource_group.cosmos.name
  short_name          = "ops"

  email_receiver {
    name          = "ops-email"
    email_address = "ops@contoso.com"
  }
}
```

---

## Reference Links

| Topic | Link |
|---|---|
| Cosmos DB Overview | https://learn.microsoft.com/azure/cosmos-db/introduction |
| High Availability | https://learn.microsoft.com/azure/cosmos-db/high-availability |
| Reliability in Cosmos DB for NoSQL | https://learn.microsoft.com/azure/reliability/reliability-cosmos-db-nosql |
| Disaster Recovery Guidance | https://learn.microsoft.com/azure/cosmos-db/disaster-recovery-guidance |
| Continuous Backup (PITR) | https://learn.microsoft.com/azure/cosmos-db/continuous-backup-restore-introduction |
| Periodic Backup | https://learn.microsoft.com/azure/cosmos-db/periodic-backup-restore-introduction |
| Global Data Distribution | https://learn.microsoft.com/azure/cosmos-db/distribute-data-globally |
| Multi-Region Writes | https://learn.microsoft.com/azure/cosmos-db/multi-region-writes |
| Consistency Levels | https://learn.microsoft.com/azure/cosmos-db/consistency-levels |
| Monitor Cosmos DB | https://learn.microsoft.com/azure/cosmos-db/monitor |
| Diagnostic Logs | https://learn.microsoft.com/azure/cosmos-db/monitor-resource-logs |
| Create Alerts | https://learn.microsoft.com/azure/cosmos-db/create-alerts |
| Monitoring Data Reference | https://learn.microsoft.com/azure/cosmos-db/monitor-reference |
| Private Endpoints | https://learn.microsoft.com/azure/cosmos-db/how-to-configure-private-endpoints |
| Terraform `azurerm_cosmosdb_account` | https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cosmosdb_account |
| AVM Cosmos DB Module | https://registry.terraform.io/modules/Azure/avm-res-documentdb-databaseaccount/azurerm/latest |
