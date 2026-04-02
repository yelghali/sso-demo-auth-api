terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.116"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.53"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.32"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
  storage_use_azuread = true

  default_tags {
    tags = {
      CostControl     = "Ignore"
      SecurityControl = "Ignore"
    }
  }
}

provider "azuread" {}

# Kubernetes provider for Cluster 1 (AGC)
provider "kubernetes" {
  alias                  = "cluster1"
  host                   = azurerm_kubernetes_cluster.aks1.kube_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.aks1.kube_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.aks1.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks1.kube_config[0].cluster_ca_certificate)
}

# Kubernetes provider for Cluster 2 (Traefik)
provider "kubernetes" {
  alias                  = "cluster2"
  host                   = azurerm_kubernetes_cluster.aks2.kube_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.aks2.kube_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.aks2.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks2.kube_config[0].cluster_ca_certificate)
}

# Helm provider for Cluster 1 (AGC)
provider "helm" {
  alias = "cluster1"
  kubernetes {
    host                   = azurerm_kubernetes_cluster.aks1.kube_config[0].host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.aks1.kube_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.aks1.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks1.kube_config[0].cluster_ca_certificate)
  }
}

# Helm provider for Cluster 2 (Traefik)
provider "helm" {
  alias = "cluster2"
  kubernetes {
    host                   = azurerm_kubernetes_cluster.aks2.kube_config[0].host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.aks2.kube_config[0].client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.aks2.kube_config[0].client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks2.kube_config[0].cluster_ca_certificate)
  }
}

# ─── Data Sources ───────────────────────────────────────────────
data "azurerm_client_config" "current" {}

# ─── Random suffix for globally unique names ────────────────────
resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
}

# ─── Locals ─────────────────────────────────────────────────────
locals {
  suffix   = random_string.suffix.result
  hostname = "${azurerm_public_ip.appgw.ip_address}.sslip.io"

  # Static IP for Traefik internal LB (from AKS2 subnet)
  traefik_ilb_ip = cidrhost(var.subnet_cidrs["aks2"], 100)

  storage_apps = {
    main = { name = "main", path = "", title = "Main Portal" }
    app1 = { name = "app1", path = "app1", title = "Orders App" }
    app2 = { name = "app2", path = "app2", title = "Users App" }
    app3 = { name = "app3", path = "app3", title = "Products App" }
  }

  api_services = ["orders", "users", "products"]
}

# ─── Resource Group ─────────────────────────────────────────────
resource "azurerm_resource_group" "main" {
  name     = "${var.prefix}-rg"
  location = var.location
}
