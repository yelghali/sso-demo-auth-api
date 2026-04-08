# Operating Model — Azure Database for PostgreSQL Flexible Server

> **Last updated:** April 2026  
> **Terraform provider:** `azurerm` (hashicorp/azurerm)  
> **Recommended Tier:** General Purpose or Memory Optimized (required for HA)

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

Azure Database for PostgreSQL Flexible Server is a fully managed database service providing granular control over database configuration and tuning. It supports zone-redundant and same-zone HA, automated backups with PITR, geo-redundant backup, read replicas, and rich monitoring via Azure Monitor.

---

## Recommended Configuration

| Setting | Recommended Value | Notes |
|---|---|---|
| Compute Tier | General Purpose or Memory Optimized | Required for HA; Burstable does not support HA |
| HA Mode | Zone-redundant | Standby in different AZ for zone-level protection |
| Backup Retention | 7–35 days | Default is 7; set based on RPO |
| Geo-Redundant Backup | `Enabled` | For cross-region DR; available in selected regions |
| Storage Auto-Grow | `Enabled` | Prevent outages from storage exhaustion |
| SSL Enforcement | `Enabled` | Mandatory for production |
| Private Network Access | VNet integration or Private Link | No public IP for production |
| Authentication | Entra ID (AAD) + PostgreSQL | Prefer managed identity where possible |
| Maintenance Window | Custom (off-peak) | Reduce impact of planned maintenance |
| Resource Lock | `CanNotDelete` | Prevent accidental deletion |
| Server Parameters | `metrics.collector_database_activity = ON` | Enable enhanced monitoring metrics |

---

## High Availability (HA)

### Architecture
- **Primary server** handles all reads and writes.
- **Standby replica** receives WAL stream in **synchronous** replication mode.
- Write commits are acknowledged only after WAL is persisted on both primary and standby.
- DNS entry is automatically updated during failover.

### HA Modes

| Mode | Description | Protection |
|---|---|---|
| Zone-Redundant HA | Primary and standby in different AZs | Zone-level failure protection |
| Same-Zone HA | Primary and standby in same AZ | Node-level failure protection |

### Failover

| Type | Trigger | RTO | RPO |
|---|---|---|---|
| Planned Failover | User-initiated (maintenance, testing) | < 120s | Zero data loss |
| Unplanned Failover | Automatic on primary failure | < 120s | Zero data loss |

### HA Status Values

| Status | Description |
|---|---|
| **Initializing** | Creating standby server |
| **Replicating Data** | Standby catching up with primary |
| **Healthy** | Replication steady state |
| **Failing Over** | Failover in progress |
| **Removing Standby** | Deleting standby server |
| **Not Enabled** | HA not configured |

---

## Health Checks

### Database Availability Metric
- **`is_db_alive`** — Returns `1` (available) or `0` (unavailable). Emitted every minute with 93 days retention.
- Set an alert on `is_db_alive == 0` for immediate notification.

### HA Health Status Monitoring
- Uses Azure **Resource Health Check (RHC)** framework.
- Health states: **Ready**, **Degraded** (NSG blocking, read-only, HA degraded), **Unavailable**.
- Portal: **Server → Help → Resource Health**.

### Connection-Based Health Check
```sql
-- Simple connectivity check
SELECT 1;

-- Check replication status (on primary)
SELECT * FROM pg_stat_replication;

-- Check recovery status (on standby)
SELECT pg_is_in_recovery();
```

### Application-Level Health Probe
```bash
# TCP check
pg_isready -h <server>.postgres.database.azure.com -p 5432

# Full query check
psql "host=<server>.postgres.database.azure.com dbname=postgres user=<admin> sslmode=require" -c "SELECT 1;"
```

---

## Backup & Restore

### Automated Backups
- **Full snapshot backups:** Daily.
- **WAL (transaction log) backups:** Continuous.
- **Retention:** 7–35 days (configurable).
- **Storage:** Zone-redundant storage (ZRS) in regions with AZ support.
- Backups do **not** affect performance or availability.

### Geo-Redundant Backup
- Backup data is copied to the **paired region**.
- Enables **geo-restore** to a different region during regional outage.
- RPO: up to last backup replication lag.

### Point-in-Time Restore (PITR)
- Restore to **any second** within the retention window.
- Creates a **new server** (does not overwrite existing).
- Supports: latest restore point, custom restore point, full backup (fast restore).

### Restore Procedures

```bash
# Restore to latest point in time
az postgres flexible-server restore \
  --resource-group <rg> \
  --name <new-server-name> \
  --source-server <source-server-name> \
  --restore-time "2026-04-08T10:00:00Z"

# Geo-restore to paired region
az postgres flexible-server geo-restore \
  --resource-group <rg> \
  --name <new-server-name> \
  --source-server <source-server-id> \
  --location <paired-region>
```

### Manual Backup (pg_dump)
```bash
# Logical backup
pg_dump -h <server>.postgres.database.azure.com -U <admin> -d <dbname> -Fc -f backup.dump

# Restore to new server
pg_restore -h <new-server>.postgres.database.azure.com -U <admin> -d <dbname> backup.dump
```

---

## Monitoring & Alerting

### Key Metrics

| Metric | ID | Description | Alert On |
|---|---|---|---|
| CPU Percent | `cpu_percent` | Server CPU utilization | > 80% sustained |
| Memory Percent | `memory_percent` | Server memory utilization | > 80% sustained |
| Storage Percent | `storage_percent` | Storage used vs. provisioned | > 85% |
| Active Connections | `active_connections` | Current active connections | Near max_connections |
| Database Is Alive | `is_db_alive` | Database availability | == 0 |
| Network In/Out | `network_bytes_ingress/egress` | Network traffic | Anomaly |
| Read/Write IOPS | `read_iops`, `write_iops` | Disk I/O operations | Near provisioned limit |
| Replication Lag | `physical_replication_lag` | Standby replication delay | > 30s |
| Transaction Log Storage | `txlogs_storage_used` | WAL storage consumed | > threshold |
| Failed Connections | `connections_failed` | Authentication/connection errors | > 10 in 5 min |

### Enhanced Metrics (Enable via Server Parameter)
Set `metrics.collector_database_activity = ON` to unlock per-database metrics:
- Active/idle/waiting client connections
- Pooled connections (PgBouncer)
- Autovacuum diagnostics

### Diagnostic Settings
Route logs to Log Analytics workspace:
- **PostgreSQLLogs** — Server logs
- **PostgreSQLFlexSessionsData** — Session-level data
- **PostgreSQLFlexQueryStoreRuntime** — Query Store runtime stats
- **PostgreSQLFlexQueryStoreWaitStats** — Query Store wait stats
- **PostgreSQLFlexDatabaseXacts** — Database transactions

### Recommended Alert Rules

| Alert | Condition | Severity |
|---|---|---|
| Database down | `is_db_alive == 0` | Critical (Sev 0) |
| High CPU | `cpu_percent > 80` for 15 min | Warning (Sev 2) |
| High memory | `memory_percent > 80` for 15 min | Warning (Sev 2) |
| Storage near full | `storage_percent > 85` | Critical (Sev 1) |
| High replication lag | `physical_replication_lag > 30s` | Warning (Sev 2) |
| Connection failures | `connections_failed > 10` in 5 min | Warning (Sev 2) |
| Active connections high | `active_connections > 80%` of max | Warning (Sev 2) |

---

## Disaster Recovery (DR)

### Strategy Matrix

| Scenario | Without HA | With Zone-Redundant HA |
|---|---|---|
| **Node failure** | PITR to new server | Automatic failover (< 120s, zero data loss) |
| **AZ failure** | PITR to different AZ | Automatic failover to standby AZ |
| **Region failure** | Geo-restore from backup; or promote read replica | Geo-restore from backup; or promote read replica |
| **Logical error** (accidental drop) | PITR to time before error | PITR (HA does NOT protect against logical errors) |

### Cross-Region DR Options

1. **Geo-Redundant Backup + Geo-Restore**
   - RPO: up to last backup replication lag
   - RTO: minutes to hours depending on data size

2. **Read Replica (Cross-Region)**
   - Asynchronous replication to another region.
   - Promote replica to standalone in DR event.
   - RPO: seconds to minutes (replication lag at time of failure).

3. **pg_dump/pg_restore (Manual)**
   - Scheduled logical backups to secondary storage/region.
   - Higher RTO but gives full flexibility.

### DR Testing
- Perform planned failover to validate HA behavior.
- Test PITR restore to verify backup integrity.
- Promote a read replica and validate application connectivity.

---

## Terraform Examples

### PostgreSQL Flexible Server with HA, Monitoring, and Geo-Redundant Backup

```hcl
# --- Variables ---
variable "location" {
  default = "eastus2"
}

variable "resource_group_name" {
  default = "rg-postgres-prod"
}

variable "admin_password" {
  type      = string
  sensitive = true
}

# --- Resource Group ---
resource "azurerm_resource_group" "pg" {
  name     = var.resource_group_name
  location = var.location
}

# --- Log Analytics Workspace ---
resource "azurerm_log_analytics_workspace" "pg" {
  name                = "law-postgres-prod"
  location            = azurerm_resource_group.pg.location
  resource_group_name = azurerm_resource_group.pg.name
  sku                 = "PerGB2018"
  retention_in_days   = 90
}

# --- Delegated Subnet for PostgreSQL ---
resource "azurerm_subnet" "pg" {
  name                 = "snet-postgres"
  resource_group_name  = azurerm_resource_group.pg.name
  virtual_network_name = var.vnet_name
  address_prefixes     = ["10.0.4.0/24"]

  delegation {
    name = "postgresql-delegation"
    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

# --- Private DNS Zone ---
resource "azurerm_private_dns_zone" "pg" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.pg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "pg" {
  name                  = "pg-dns-vnet-link"
  private_dns_zone_name = azurerm_private_dns_zone.pg.name
  virtual_network_id    = var.vnet_id
  resource_group_name   = azurerm_resource_group.pg.name
}

# --- PostgreSQL Flexible Server ---
resource "azurerm_postgresql_flexible_server" "main" {
  name                          = "psql-prod-contoso"
  resource_group_name           = azurerm_resource_group.pg.name
  location                      = azurerm_resource_group.pg.location
  version                       = "16"
  delegated_subnet_id           = azurerm_subnet.pg.id
  private_dns_zone_id           = azurerm_private_dns_zone.pg.id
  public_network_access_enabled = false

  administrator_login    = "pgadmin"
  administrator_password = var.admin_password

  sku_name   = "GP_Standard_D4s_v3"
  storage_mb = 65536
  storage_tier = "P30"

  zone = "1"

  backup_retention_days        = 35
  geo_redundant_backup_enabled = true

  auto_grow_enabled = true

  high_availability {
    mode                      = "ZoneRedundant"
    standby_availability_zone = "2"
  }

  maintenance_window {
    day_of_week  = 0 # Sunday
    start_hour   = 2
    start_minute = 0
  }

  authentication {
    active_directory_auth_enabled = true
    password_auth_enabled         = true
  }

  tags = {
    environment = "production"
    managed_by  = "terraform"
  }
}

# --- Server Parameters ---
resource "azurerm_postgresql_flexible_server_configuration" "enhanced_metrics" {
  name      = "metrics.collector_database_activity"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "on"
}

resource "azurerm_postgresql_flexible_server_configuration" "log_checkpoints" {
  name      = "log_checkpoints"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "on"
}

resource "azurerm_postgresql_flexible_server_configuration" "log_connections" {
  name      = "log_connections"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "on"
}

# --- Resource Lock ---
resource "azurerm_management_lock" "pg_lock" {
  name       = "pg-delete-lock"
  scope      = azurerm_postgresql_flexible_server.main.id
  lock_level = "CanNotDelete"
  notes      = "Prevent accidental deletion of production PostgreSQL server"
}

# --- Diagnostic Settings ---
resource "azurerm_monitor_diagnostic_setting" "pg" {
  name                       = "pg-diag-loganalytics"
  target_resource_id         = azurerm_postgresql_flexible_server.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.pg.id

  enabled_log {
    category = "PostgreSQLLogs"
  }

  enabled_log {
    category = "PostgreSQLFlexQueryStoreRuntime"
  }

  enabled_log {
    category = "PostgreSQLFlexQueryStoreWaitStats"
  }

  enabled_log {
    category = "PostgreSQLFlexSessionsData"
  }

  enabled_log {
    category = "PostgreSQLFlexDatabaseXacts"
  }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

# --- Alert: Database Down ---
resource "azurerm_monitor_metric_alert" "pg_alive" {
  name                = "pg-db-alive-alert"
  resource_group_name = azurerm_resource_group.pg.name
  scopes              = [azurerm_postgresql_flexible_server.main.id]
  description         = "Alert when PostgreSQL database is not alive"
  severity            = 0
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "is_db_alive"
    aggregation      = "Minimum"
    operator         = "LessThan"
    threshold        = 1
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}

# --- Alert: High CPU ---
resource "azurerm_monitor_metric_alert" "pg_cpu" {
  name                = "pg-high-cpu-alert"
  resource_group_name = azurerm_resource_group.pg.name
  scopes              = [azurerm_postgresql_flexible_server.main.id]
  description         = "Alert on sustained high CPU"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "cpu_percent"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}

# --- Alert: Storage Near Full ---
resource "azurerm_monitor_metric_alert" "pg_storage" {
  name                = "pg-storage-alert"
  resource_group_name = azurerm_resource_group.pg.name
  scopes              = [azurerm_postgresql_flexible_server.main.id]
  description         = "Alert when storage usage exceeds 85%"
  severity            = 1
  frequency           = "PT15M"
  window_size         = "PT1H"

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "storage_percent"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 85
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops.id
  }
}

# --- Action Group ---
resource "azurerm_monitor_action_group" "ops" {
  name                = "ag-ops-team"
  resource_group_name = azurerm_resource_group.pg.name
  short_name          = "ops"

  email_receiver {
    name          = "ops-email"
    email_address = "ops@contoso.com"
  }
}

# --- Read Replica (Cross-Region DR) ---
resource "azurerm_postgresql_flexible_server" "replica" {
  name                = "psql-replica-contoso"
  resource_group_name = azurerm_resource_group.pg.name
  location            = "westus2"

  create_mode      = "Replica"
  source_server_id = azurerm_postgresql_flexible_server.main.id

  sku_name   = "GP_Standard_D4s_v3"
  storage_mb = 65536

  tags = {
    environment = "production"
    role        = "read-replica-dr"
    managed_by  = "terraform"
  }
}
```

---

## Reference Links

| Topic | Link |
|---|---|
| PostgreSQL Flexible Server Overview | https://learn.microsoft.com/azure/postgresql/flexible-server/overview |
| High Availability Concepts | https://learn.microsoft.com/azure/postgresql/high-availability/concepts-high-availability |
| Configure HA | https://learn.microsoft.com/azure/postgresql/high-availability/how-to-configure-high-availability |
| HA Health Monitoring | https://learn.microsoft.com/azure/postgresql/high-availability/how-to-monitor-high-availability |
| Reliability in PostgreSQL | https://learn.microsoft.com/azure/reliability/reliability-postgresql-flexible-server |
| Business Continuity | https://learn.microsoft.com/azure/postgresql/backup-restore/concepts-business-continuity |
| Backup & Restore Concepts | https://learn.microsoft.com/azure/postgresql/backup-restore/concepts-backup-restore |
| Point-in-Time Restore | https://learn.microsoft.com/azure/postgresql/backup-restore/how-to-restore-latest-restore-point |
| Geo-Restore | https://learn.microsoft.com/azure/postgresql/backup-restore/how-to-restore-paired-region |
| Read Replicas | https://learn.microsoft.com/azure/postgresql/read-replica/concepts-read-replicas |
| Monitoring Metrics | https://learn.microsoft.com/azure/postgresql/monitor/concepts-monitoring |
| Alerting on Metrics | https://learn.microsoft.com/azure/postgresql/monitor/how-to-alert-on-metrics |
| Diagnostic Logs | https://learn.microsoft.com/azure/postgresql/monitor/concepts-logging |
| Terraform `azurerm_postgresql_flexible_server` | https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/postgresql_flexible_server |
