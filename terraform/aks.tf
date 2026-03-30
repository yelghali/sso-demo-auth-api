# ─── User-Assigned Identity for AKS Clusters ───────────────────
resource "azurerm_user_assigned_identity" "aks1" {
  name                = "${var.prefix}-aks1-id"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

resource "azurerm_user_assigned_identity" "aks2" {
  name                = "${var.prefix}-aks2-id"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

# ─── Role: AKS identity needs Network Contributor on its subnet ─
resource "azurerm_role_assignment" "aks1_network" {
  scope                = azurerm_subnet.aks1.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks1.principal_id
}

resource "azurerm_role_assignment" "aks2_network" {
  scope                = azurerm_subnet.aks2.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks2.principal_id
}

# ─── AKS Cluster 1 (AGC Ingress) ───────────────────────────────
resource "azurerm_kubernetes_cluster" "aks1" {
  name                = "${var.prefix}-aks1-agc"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  dns_prefix          = "${var.prefix}-aks1"
  kubernetes_version  = "1.33"

  default_node_pool {
    name           = "default"
    node_count     = var.aks_node_count
    vm_size        = var.aks_node_size
    vnet_subnet_id = azurerm_subnet.aks1.id
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks1.id]
  }

  network_profile {
    network_plugin = "azure"
    service_cidr   = "10.1.0.0/16"
    dns_service_ip = "10.1.0.10"
  }

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  depends_on = [azurerm_role_assignment.aks1_network]
}

# ─── AKS Cluster 2 (Traefik + Internal LB) ─────────────────────
resource "azurerm_kubernetes_cluster" "aks2" {
  name                = "${var.prefix}-aks2-traefik"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  dns_prefix          = "${var.prefix}-aks2"
  kubernetes_version  = "1.33"

  default_node_pool {
    name           = "default"
    node_count     = var.aks_node_count
    vm_size        = var.aks_node_size
    vnet_subnet_id = azurerm_subnet.aks2.id
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks2.id]
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    pod_cidr            = "192.169.0.0/16"
    service_cidr        = "10.2.0.0/16"
    dns_service_ip      = "10.2.0.10"
  }

  depends_on = [azurerm_role_assignment.aks2_network]
}

# ─── ACR Pull access for both clusters ─────────────────────────
resource "azurerm_role_assignment" "aks1_acr" {
  scope                            = azurerm_container_registry.main.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.aks1.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "aks2_acr" {
  scope                            = azurerm_container_registry.main.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.aks2.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}
