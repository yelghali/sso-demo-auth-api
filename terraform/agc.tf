# ─── App Gateway for Containers (AGC) ───────────────────────────

resource "azurerm_application_load_balancer" "main" {
  name                = "${var.prefix}-agc"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

resource "azurerm_application_load_balancer_subnet_association" "main" {
  name                         = "${var.prefix}-agc-assoc"
  application_load_balancer_id = azurerm_application_load_balancer.main.id
  subnet_id                    = azurerm_subnet.agc.id
}

resource "azurerm_application_load_balancer_frontend" "main" {
  name                         = "${var.prefix}-agc-frontend"
  application_load_balancer_id = azurerm_application_load_balancer.main.id
}

# ─── Managed Identity for ALB Controller ────────────────────────
resource "azurerm_user_assigned_identity" "alb_controller" {
  name                = "${var.prefix}-alb-controller-id"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

# ALB controller needs Reader on the RG
resource "azurerm_role_assignment" "alb_rg_reader" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.alb_controller.principal_id
}

# ALB controller needs AppGw for Containers Configuration Manager on the AGC
resource "azurerm_role_assignment" "alb_agc_config" {
  scope                = azurerm_application_load_balancer.main.id
  role_definition_name = "AppGw for Containers Configuration Manager"
  principal_id         = azurerm_user_assigned_identity.alb_controller.principal_id
}

# ALB controller needs Network Contributor on the AGC subnet
resource "azurerm_role_assignment" "alb_subnet" {
  scope                = azurerm_subnet.agc.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.alb_controller.principal_id
}

# ─── Federated Identity for Workload Identity ──────────────────
resource "azurerm_federated_identity_credential" "alb_controller" {
  name                = "alb-controller-federated"
  resource_group_name = azurerm_resource_group.main.name
  parent_id           = azurerm_user_assigned_identity.alb_controller.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.aks1.oidc_issuer_url
  subject             = "system:serviceaccount:azure-alb-system:alb-controller-sa"
}
