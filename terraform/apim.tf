# ─── Public IP for APIM management (required for stv2) ─────────
resource "azurerm_public_ip" "apim" {
  name                = "${var.prefix}-apim-pip"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "${var.prefix}-apim-${local.suffix}"
}

# ─── API Management (Developer tier, internal VNet) ─────────────
resource "azurerm_api_management" "main" {
  name                 = "${var.prefix}-apim-${local.suffix}"
  resource_group_name  = azurerm_resource_group.main.name
  location             = azurerm_resource_group.main.location
  publisher_name       = "SSO Demo"
  publisher_email      = "admin@ssodemo.local"
  sku_name             = "Developer_1"
  virtual_network_type = "Internal"

  virtual_network_configuration {
    subnet_id = azurerm_subnet.apim.id
  }

  public_ip_address_id = azurerm_public_ip.apim.id

  depends_on = [azurerm_subnet_network_security_group_association.apim]
}

# ─── APIM: AGC Backend ─────────────────────────────────────────
resource "azurerm_api_management_backend" "agc" {
  name                = "agc-backend"
  resource_group_name = azurerm_resource_group.main.name
  api_management_name = azurerm_api_management.main.name
  protocol            = "http"
  url                 = "http://${azurerm_application_load_balancer_frontend.main.fully_qualified_domain_name}"
}

# ─── APIM: Traefik ILB Backend ─────────────────────────────────
resource "azurerm_api_management_backend" "traefik" {
  name                = "traefik-backend"
  resource_group_name = azurerm_resource_group.main.name
  api_management_name = azurerm_api_management.main.name
  protocol            = "http"
  url                 = "http://${local.traefik_ilb_ip}"
}

# ─── APIM API: AGC-routed APIs ─────────────────────────────────
resource "azurerm_api_management_api" "agc" {
  name                  = "agc-apis"
  resource_group_name   = azurerm_resource_group.main.name
  api_management_name   = azurerm_api_management.main.name
  revision              = "1"
  display_name          = "APIs via AGC (Cluster 1)"
  path                  = "api/agc"
  protocols             = ["https", "http"]
  subscription_required = false
  service_url           = "http://${azurerm_application_load_balancer_frontend.main.fully_qualified_domain_name}"
}

resource "azurerm_api_management_api_operation" "agc_catchall" {
  operation_id        = "agc-catchall"
  api_name            = azurerm_api_management_api.agc.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = azurerm_resource_group.main.name
  display_name        = "Catch-All (AGC)"
  method              = "GET"
  url_template        = "/{*path}"

  template_parameter {
    name     = "path"
    type     = "string"
    required = true
  }
}

# ─── APIM API: Traefik-routed APIs ─────────────────────────────
resource "azurerm_api_management_api" "traefik" {
  name                  = "traefik-apis"
  resource_group_name   = azurerm_resource_group.main.name
  api_management_name   = azurerm_api_management.main.name
  revision              = "1"
  display_name          = "APIs via Traefik (Cluster 2)"
  path                  = "api/traefik"
  protocols             = ["https", "http"]
  subscription_required = false
  service_url           = "http://${local.traefik_ilb_ip}"
}

resource "azurerm_api_management_api_operation" "traefik_catchall" {
  operation_id        = "traefik-catchall"
  api_name            = azurerm_api_management_api.traefik.name
  api_management_name = azurerm_api_management.main.name
  resource_group_name = azurerm_resource_group.main.name
  display_name        = "Catch-All (Traefik)"
  method              = "GET"
  url_template        = "/{*path}"

  template_parameter {
    name     = "path"
    type     = "string"
    required = true
  }
}

# ─── APIM CORS Policy (allow frontend to call APIs) ────────────
resource "azurerm_api_management_policy" "global" {
  api_management_id = azurerm_api_management.main.id

  xml_content = <<-XML
    <policies>
      <inbound>
        <cors allow-credentials="true">
          <allowed-origins>
            <origin>https://${local.hostname}</origin>
          </allowed-origins>
          <allowed-methods>
            <method>GET</method>
            <method>POST</method>
            <method>OPTIONS</method>
          </allowed-methods>
          <allowed-headers>
            <header>Authorization</header>
            <header>Content-Type</header>
          </allowed-headers>
        </cors>
      </inbound>
      <backend>
        <forward-request />
      </backend>
      <outbound />
      <on-error />
    </policies>
  XML
}
