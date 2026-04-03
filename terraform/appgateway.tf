# ─── Public IP for App Gateway ──────────────────────────────────
resource "azurerm_public_ip" "appgw" {
  name                = "${var.prefix}-appgw-pip"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

# ─── Self-signed TLS certificate (demo only) ───────────────────
resource "tls_private_key" "appgw" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "appgw" {
  private_key_pem = tls_private_key.appgw.private_key_pem

  subject {
    common_name = "${azurerm_public_ip.appgw.ip_address}.sslip.io"
  }

  validity_period_hours = 8760
  allowed_uses          = ["key_encipherment", "digital_signature", "server_auth"]

  dns_names = [
    "${azurerm_public_ip.appgw.ip_address}.sslip.io",
  ]
}

# Generate PKCS12/PFX from PEM using PowerShell
data "external" "appgw_pfx" {
  program = ["pwsh", "-Command", <<-EOT
    $input_json = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($input_json.cert_pem, $input_json.key_pem)
    $pfxBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, 'terraform')
    $b64 = [Convert]::ToBase64String($pfxBytes)
    @{ pfx_base64 = $b64 } | ConvertTo-Json
  EOT
  ]

  query = {
    cert_pem = tls_self_signed_cert.appgw.cert_pem
    key_pem  = tls_private_key.appgw.private_key_pem
  }
}

# ─── WAF Policy ────────────────────────────────────────────────
resource "azurerm_web_application_firewall_policy" "main" {
  name                = "${var.prefix}-waf-policy"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  policy_settings {
    enabled                     = true
    mode                        = "Prevention"
    request_body_check          = true
    file_upload_limit_in_mb     = 100
    max_request_body_size_in_kb = 128
  }

  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
    }
  }
}

# ─── Application Gateway v2 with WAF ───────────────────────────
resource "azurerm_application_gateway" "main" {
  name                = "${var.prefix}-appgw"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  firewall_policy_id  = azurerm_web_application_firewall_policy.main.id

  sku {
    name     = "WAF_v2"
    tier     = "WAF_v2"
    capacity = 1
  }

  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101"
  }

  gateway_ip_configuration {
    name      = "gateway-ip-config"
    subnet_id = azurerm_subnet.appgw.id
  }

  # ── Frontend ──────────────────────────────────────────────────
  frontend_ip_configuration {
    name                 = "frontend-ip"
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  frontend_port {
    name = "https-port"
    port = 443
  }

  frontend_port {
    name = "http-port"
    port = 80
  }

  # ── SSL Certificate ──────────────────────────────────────────
  ssl_certificate {
    name     = "appgw-ssl-cert"
    data     = data.external.appgw_pfx.result.pfx_base64
    password = "terraform"
  }

  # ── HTTPS Listener ──────────────────────────────────────────
  http_listener {
    name                           = "https-listener"
    frontend_ip_configuration_name = "frontend-ip"
    frontend_port_name             = "https-port"
    protocol                       = "Https"
    ssl_certificate_name           = "appgw-ssl-cert"
    host_name                      = "${azurerm_public_ip.appgw.ip_address}.sslip.io"
  }

  # ── HTTP → HTTPS redirect listener ──────────────────────────
  http_listener {
    name                           = "http-listener"
    frontend_ip_configuration_name = "frontend-ip"
    frontend_port_name             = "http-port"
    protocol                       = "Http"
  }

  # ── Backend Pools ─────────────────────────────────────────────

  # Storage: Main portal
  backend_address_pool {
    name  = "pool-main"
    fqdns = [azurerm_storage_account.frontend["main"].primary_web_host]
  }

  # Storage: App 1
  backend_address_pool {
    name  = "pool-app1"
    fqdns = [azurerm_storage_account.frontend["app1"].primary_web_host]
  }

  # Storage: App 2
  backend_address_pool {
    name  = "pool-app2"
    fqdns = [azurerm_storage_account.frontend["app2"].primary_web_host]
  }

  # Storage: App 3
  backend_address_pool {
    name  = "pool-app3"
    fqdns = [azurerm_storage_account.frontend["app3"].primary_web_host]
  }

  # APIM (internal)
  backend_address_pool {
    name  = "pool-apim"
    fqdns = [replace(replace(azurerm_api_management.main.gateway_url, "https://", ""), "/", "")]
  }

  # AGC frontend (AKS-hosted frontend — bypasses APIM)
  backend_address_pool {
    name  = "pool-agc"
    fqdns = [azurerm_application_load_balancer_frontend.main.fully_qualified_domain_name]
  }

  # NGINX ILB (legacy APIs on Cluster 1 — through APIM or direct)
  backend_address_pool {
    name         = "pool-nginx"
    ip_addresses = [local.nginx_ilb_ip]
  }

  # ── Backend HTTP Settings ─────────────────────────────────────

  # Settings for Storage backends (HTTPS, host header override)
  dynamic "backend_http_settings" {
    for_each = local.storage_apps
    content {
      name                  = "settings-${backend_http_settings.key}"
      cookie_based_affinity = "Disabled"
      port                  = 443
      protocol              = "Https"
      request_timeout       = 30
      host_name             = azurerm_storage_account.frontend[backend_http_settings.key].primary_web_host
      probe_name            = "probe-storage-${backend_http_settings.key}"
    }
  }

  # Settings for APIM backend
  backend_http_settings {
    name                  = "settings-apim"
    cookie_based_affinity = "Disabled"
    port                  = 443
    protocol              = "Https"
    request_timeout       = 60
    host_name             = replace(replace(azurerm_api_management.main.gateway_url, "https://", ""), "/", "")
    probe_name            = "probe-apim"
  }

  # Settings for AGC backend (HTTP — AGC terminates internally)
  backend_http_settings {
    name                  = "settings-agc"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 30
    host_name             = azurerm_application_load_balancer_frontend.main.fully_qualified_domain_name
    probe_name            = "probe-agc"
  }

  # Settings for NGINX ILB backend (HTTP)
  backend_http_settings {
    name                  = "settings-nginx"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 30
    host_name             = local.nginx_ilb_ip
    probe_name            = "probe-nginx"
  }

  # ── Health Probes ─────────────────────────────────────────────

  dynamic "probe" {
    for_each = local.storage_apps
    content {
      name                = "probe-storage-${probe.key}"
      protocol            = "Https"
      path                = "/"
      host                = azurerm_storage_account.frontend[probe.key].primary_web_host
      interval            = 30
      timeout             = 30
      unhealthy_threshold = 3
      match {
        status_code = ["200-404"]
      }
    }
  }

  probe {
    name                = "probe-apim"
    protocol            = "Https"
    path                = "/status-0123456789abcdef"
    host                = replace(replace(azurerm_api_management.main.gateway_url, "https://", ""), "/", "")
    interval            = 30
    timeout             = 30
    unhealthy_threshold = 3
    match {
      status_code = ["200-399"]
    }
  }

  probe {
    name                = "probe-agc"
    protocol            = "Http"
    path                = "/"
    host                = azurerm_application_load_balancer_frontend.main.fully_qualified_domain_name
    interval            = 30
    timeout             = 30
    unhealthy_threshold = 3
    match {
      status_code = ["200-404"]
    }
  }

  probe {
    name                                      = "probe-nginx"
    protocol                                  = "Http"
    path                                      = "/healthz"
    pick_host_name_from_backend_http_settings = true
    interval                                  = 30
    timeout                                   = 30
    unhealthy_threshold                       = 3
    match {
      status_code = ["200-404"]
    }
  }

  # ── URL Path Map ──────────────────────────────────────────────
  url_path_map {
    name                               = "path-map"
    default_backend_address_pool_name  = "pool-main"
    default_backend_http_settings_name = "settings-main"

    path_rule {
      name                       = "app1-rule"
      paths                      = ["/app1", "/app1/*"]
      backend_address_pool_name  = "pool-app1"
      backend_http_settings_name = "settings-app1"
      rewrite_rule_set_name      = "rewrite-app1"
    }

    path_rule {
      name                       = "app2-rule"
      paths                      = ["/app2", "/app2/*"]
      backend_address_pool_name  = "pool-app2"
      backend_http_settings_name = "settings-app2"
      rewrite_rule_set_name      = "rewrite-app2"
    }

    path_rule {
      name                       = "app3-rule"
      paths                      = ["/app3", "/app3/*"]
      backend_address_pool_name  = "pool-app3"
      backend_http_settings_name = "settings-app3"
      rewrite_rule_set_name      = "rewrite-app3"
    }

    path_rule {
      name                       = "api-rule"
      paths                      = ["/api", "/api/*"]
      backend_address_pool_name  = "pool-apim"
      backend_http_settings_name = "settings-apim"
    }

    # Scenario B: Frontend on AKS — App Gateway → APIM → NGINX ILB → NGINX pods
    # Static frontend served by NGINX Ingress, routed via APIM
    path_rule {
      name                       = "aks-app-rule"
      paths                      = ["/aks-app", "/aks-app/*"]
      backend_address_pool_name  = "pool-apim"
      backend_http_settings_name = "settings-apim"
    }

    # Legacy routes — App Gateway → APIM → NGINX ILB
    path_rule {
      name                       = "legacy-direct-rule"
      paths                      = ["/legacy", "/legacy/*"]
      backend_address_pool_name  = "pool-apim"
      backend_http_settings_name = "settings-apim"
    }
  }

  # ── Rewrite Rule Sets (strip /appN prefix for storage) ───────

  rewrite_rule_set {
    name = "rewrite-app1"
    rewrite_rule {
      name          = "strip-app1-prefix"
      rule_sequence = 100
      condition {
        variable    = "var_uri_path"
        pattern     = "/app1(.*)"
        ignore_case = true
      }
      url {
        path    = "{var_uri_path_1}"
        reroute = false
      }
    }
  }

  rewrite_rule_set {
    name = "rewrite-app2"
    rewrite_rule {
      name          = "strip-app2-prefix"
      rule_sequence = 100
      condition {
        variable    = "var_uri_path"
        pattern     = "/app2(.*)"
        ignore_case = true
      }
      url {
        path    = "{var_uri_path_1}"
        reroute = false
      }
    }
  }

  rewrite_rule_set {
    name = "rewrite-app3"
    rewrite_rule {
      name          = "strip-app3-prefix"
      rule_sequence = 100
      condition {
        variable    = "var_uri_path"
        pattern     = "/app3(.*)"
        ignore_case = true
      }
      url {
        path    = "{var_uri_path_1}"
        reroute = false
      }
    }
  }

  # ── Request Routing Rules ─────────────────────────────────────

  # HTTPS routing with path map
  request_routing_rule {
    name               = "https-path-routing"
    rule_type          = "PathBasedRouting"
    http_listener_name = "https-listener"
    url_path_map_name  = "path-map"
    priority           = 100
  }

  # HTTP → HTTPS redirect
  request_routing_rule {
    name                        = "http-to-https-redirect"
    rule_type                   = "Basic"
    http_listener_name          = "http-listener"
    redirect_configuration_name = "http-to-https"
    priority                    = 200
  }

  redirect_configuration {
    name                 = "http-to-https"
    redirect_type        = "Permanent"
    target_listener_name = "https-listener"
    include_path         = true
    include_query_string = true
  }

  depends_on = [
    azurerm_subnet_network_security_group_association.appgw,
    azurerm_api_management.main,
  ]
}
