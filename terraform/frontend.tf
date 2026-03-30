# ─── Upload Frontend HTML to Storage Accounts ──────────────────

# Wait for RBAC propagation before blob uploads
resource "time_sleep" "rbac_propagation" {
  depends_on      = [azurerm_role_assignment.deployer_blob]
  create_duration = "60s"
}

# Main portal
resource "azurerm_storage_blob" "main_portal" {
  name                   = "index.html"
  storage_account_name   = azurerm_storage_account.frontend["main"].name
  storage_container_name = "$web"
  type                   = "Block"
  content_type           = "text/html"

  source_content = templatefile("${path.module}/templates/main-portal.html.tftpl", {
    client_id = azuread_application.main.client_id
    tenant_id = data.azurerm_client_config.current.tenant_id
    base_url  = "https://${local.hostname}"
  })

  depends_on = [time_sleep.rbac_propagation]
}

# Sub-app 1: Orders
resource "azurerm_storage_blob" "app1" {
  name                   = "index.html"
  storage_account_name   = azurerm_storage_account.frontend["app1"].name
  storage_container_name = "$web"
  type                   = "Block"
  content_type           = "text/html"

  source_content = templatefile("${path.module}/templates/sub-app.html.tftpl", {
    client_id        = azuread_application.main.client_id
    tenant_id        = data.azurerm_client_config.current.tenant_id
    base_url         = "https://${local.hostname}"
    app_path         = "app1"
    app_title        = "Orders App"
    app_description  = "Order management - SSO session inherited from Main Portal"
    app_icon         = "&#128230;"
    app_color        = "#00897b"
    app_color_dark   = "#00695c"
    api_path         = "orders"
    api_display_name = "Orders"
  })

  depends_on = [time_sleep.rbac_propagation]
}

# Sub-app 2: Users
resource "azurerm_storage_blob" "app2" {
  name                   = "index.html"
  storage_account_name   = azurerm_storage_account.frontend["app2"].name
  storage_container_name = "$web"
  type                   = "Block"
  content_type           = "text/html"

  source_content = templatefile("${path.module}/templates/sub-app.html.tftpl", {
    client_id        = azuread_application.main.client_id
    tenant_id        = data.azurerm_client_config.current.tenant_id
    base_url         = "https://${local.hostname}"
    app_path         = "app2"
    app_title        = "Users App"
    app_description  = "User management - SSO session inherited from Main Portal"
    app_icon         = "&#128101;"
    app_color        = "#5c6bc0"
    app_color_dark   = "#3949ab"
    api_path         = "users"
    api_display_name = "Users"
  })

  depends_on = [time_sleep.rbac_propagation]
}

# Sub-app 3: Products
resource "azurerm_storage_blob" "app3" {
  name                   = "index.html"
  storage_account_name   = azurerm_storage_account.frontend["app3"].name
  storage_container_name = "$web"
  type                   = "Block"
  content_type           = "text/html"

  source_content = templatefile("${path.module}/templates/sub-app.html.tftpl", {
    client_id        = azuread_application.main.client_id
    tenant_id        = data.azurerm_client_config.current.tenant_id
    base_url         = "https://${local.hostname}"
    app_path         = "app3"
    app_title        = "Products App"
    app_description  = "Product catalog - SSO session inherited from Main Portal"
    app_icon         = "&#128722;"
    app_color        = "#ef6c00"
    app_color_dark   = "#e65100"
    api_path         = "products"
    api_display_name = "Products"
  })

  depends_on = [time_sleep.rbac_propagation]
}
