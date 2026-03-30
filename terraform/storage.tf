# ─── Storage Accounts for Static Websites ───────────────────────
# One storage account per frontend app (main + 3 sub-apps)

resource "azurerm_storage_account" "frontend" {
  for_each = local.storage_apps

  name                     = "st${replace(var.prefix, "-", "")}${each.key}${local.suffix}"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  # Serve static website
  static_website {
    index_document     = "index.html"
    error_404_document = "index.html"
  }

  # Allow shared key for Terraform data-plane operations (blob upload)
  shared_access_key_enabled = false

  # Allow public access for deployment; App Gateway reaches via PE
  public_network_access_enabled   = true
  allow_nested_items_to_be_public = false
}

# ─── Role: deploying user needs Blob Data Contributor for Entra-based access ─
resource "azurerm_role_assignment" "deployer_blob" {
  for_each = local.storage_apps

  scope                = azurerm_storage_account.frontend[each.key].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ─── Private Endpoints for each Storage Account (web) ──────────

resource "azurerm_private_endpoint" "storage_web" {
  for_each = local.storage_apps

  name                = "${var.prefix}-pe-${each.key}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  subnet_id           = azurerm_subnet.pe.id

  private_service_connection {
    name                           = "${var.prefix}-psc-${each.key}"
    private_connection_resource_id = azurerm_storage_account.frontend[each.key].id
    subresource_names              = ["web"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "storage-web-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.storage_web.id]
  }
}
