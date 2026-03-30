# ─── Private DNS Zone for Storage Static Website ────────────────
resource "azurerm_private_dns_zone" "storage_web" {
  name                = "privatelink.web.core.windows.net"
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "storage_web" {
  name                  = "storage-web-vnet-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.storage_web.name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
}

# ─── Private DNS Zone for APIM (internal VNet mode) ─────────────
resource "azurerm_private_dns_zone" "apim" {
  name                = "azure-api.net"
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "apim" {
  name                  = "apim-vnet-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.apim.name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
}

resource "azurerm_private_dns_a_record" "apim" {
  name                = azurerm_api_management.main.name
  zone_name           = azurerm_private_dns_zone.apim.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = azurerm_api_management.main.private_ip_addresses
}
