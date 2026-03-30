# ─── Key Outputs ────────────────────────────────────────────────

output "resource_group" {
  value = azurerm_resource_group.main.name
}

output "app_url" {
  value       = "https://${local.hostname}"
  description = "Main portal URL (self-signed cert — accept browser warning)"
}

output "app_gateway_public_ip" {
  value = azurerm_public_ip.appgw.ip_address
}

output "entra_client_id" {
  value = azuread_application.main.client_id
}

output "entra_tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "acr_login_server" {
  value = azurerm_container_registry.main.login_server
}

output "aks1_name" {
  value = azurerm_kubernetes_cluster.aks1.name
}

output "aks2_name" {
  value = azurerm_kubernetes_cluster.aks2.name
}

output "apim_gateway_url" {
  value = azurerm_api_management.main.gateway_url
}

output "agc_frontend_fqdn" {
  value = azurerm_application_load_balancer_frontend.main.fully_qualified_domain_name
}

output "traefik_ilb_ip" {
  value = local.traefik_ilb_ip
}

output "storage_accounts" {
  value = { for k, v in azurerm_storage_account.frontend : k => v.name }
}

# ── How to build & push the API image ──────────────────────────
output "build_command" {
  value       = "az acr build --registry ${azurerm_container_registry.main.name} --image demo-api:latest ../apis/"
  description = "Run this from the terraform/ directory to build and push the API image"
}
