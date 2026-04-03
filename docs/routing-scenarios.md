# Routing Scenarios — Step-by-Step Guide

This guide covers three end-to-end routing scenarios deployed on Azure, all managed by Terraform. Each scenario shows how traffic flows from the public internet to backend services through different combinations of App Gateway, APIM, AGC, and ingress controllers.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Network Architecture Overview](#network-architecture-overview)
- [Scenario A — App Gateway → APIM → AGC → AKS APIs](#scenario-a--app-gateway--apim--agc--aks-apis)
- [Scenario B — Frontend on AKS (App Gateway → AGC → NGINX pod)](#scenario-b--frontend-on-aks-app-gateway--agc--nginx-pod)
- [Scenario C — AGC + NGINX Ingress Co-Existence on the Same Cluster](#scenario-c--agc--nginx-ingress-co-existence-on-the-same-cluster)
- [Terraform Reference](#terraform-reference)
- [Deployment](#deployment)
- [Validation & Testing](#validation--testing)
- [FAQ](#faq)

---

## Prerequisites

| Tool        | Version  | Purpose                        |
| ----------- | -------- | ------------------------------ |
| Terraform   | ≥ 1.5    | Infrastructure as Code         |
| Azure CLI   | ≥ 2.60   | Azure resource management      |
| kubectl     | ≥ 1.28   | Kubernetes cluster interaction |
| Helm        | ≥ 3.14   | Kubernetes package manager     |
| PowerShell  | ≥ 7.4    | Deployment scripts             |

```powershell
# Verify installations
terraform version
az version
kubectl version --client
helm version
```

---

## Network Architecture Overview

All resources sit within a single VNet (`10.0.0.0/16`):

```
┌────────────────────────────────────────────────────────────────────────────┐
│  VNet: 10.0.0.0/16                                                        │
│                                                                            │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────────────┐ │
│  │ snet-appgw        │  │ snet-apim        │  │ snet-agc                 │ │
│  │ 10.0.1.0/24       │  │ 10.0.3.0/24      │  │ 10.0.4.0/24              │ │
│  │ App Gateway (WAF) │  │ APIM (Internal)  │  │ App GW for Containers    │ │
│  └──────────────────┘  └──────────────────┘  └──────────────────────────┘ │
│                                                                            │
│  ┌───────────────────────────────┐  ┌──────────────────────────────────┐  │
│  │ snet-aks-cluster1             │  │ snet-aks-cluster2                │  │
│  │ 10.0.16.0/22                  │  │ 10.0.20.0/22                     │  │
│  │ AKS1: AGC + NGINX Ingress    │  │ AKS2: Traefik Ingress            │  │
│  │ ┌────────┐ ┌───────────────┐ │  │ ┌────────────────────────────┐   │  │
│  │ │ AGC    │ │ NGINX Ingress │ │  │ │ Traefik ILB @ .20.100      │   │  │
│  │ │ (GW    │ │ ILB @ .16.100│ │  │ └────────────────────────────┘   │  │
│  │ │  API)  │ └───────────────┘ │  │                                  │  │
│  │ └────────┘                   │  │                                  │  │
│  └───────────────────────────────┘  └──────────────────────────────────┘  │
│                                                                            │
│  ┌──────────────────┐                                                     │
│  │ snet-pe           │                                                     │
│  │ 10.0.2.0/24       │                                                     │
│  │ Private Endpoints │                                                     │
│  └──────────────────┘                                                     │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## Scenario A — App Gateway → APIM → AGC → AKS APIs

**Use case:** API backends running on AKS, exposed through APIM for policy enforcement (rate limiting, JWT validation, CORS), fronted by App Gateway WAF for TLS and DDoS protection.

### Traffic Flow

```
Browser                             
  │ HTTPS                          
  ▼                                 
App Gateway (WAF_v2)               
  │ Path: /api/*                   
  │ Backend: APIM (internal)       
  ▼                                 
APIM (Developer tier, Internal VNet)
  │ Policies: CORS, rate-limit,    
  │ JWT validation, logging         
  │ Routes: /api/agc/* → AGC       
  │         /api/traefik/* → Traefik
  │         /api/nginx/* → NGINX   
  ▼                                 
AGC / Traefik / NGINX (in-cluster)  
  │ HTTPRoute / Ingress rules       
  ▼                                 
AKS Pod (Flask API)                
```

### Step 1 — Create the AKS Cluster with AGC

```hcl
# terraform/aks.tf — AKS Cluster 1 with Azure CNI
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
}
```

### Step 2 — Deploy App Gateway for Containers (AGC)

AGC is Azure's next-gen Layer 7 load balancer for Kubernetes. It uses the Gateway API specification.

```hcl
# terraform/agc.tf — AGC resource + controller identity
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
```

The ALB controller runs on the cluster and reconciles Gateway API resources:

```hcl
# terraform/k8s-cluster1.tf — ALB Controller Helm Chart
resource "helm_release" "alb_controller" {
  provider         = helm.cluster1
  name             = "alb-controller"
  namespace        = "azure-alb-system"
  create_namespace = true
  repository       = "oci://mcr.microsoft.com/application-lb/charts"
  chart            = "alb-controller"
  version          = "1.3.7"

  set {
    name  = "albController.podIdentity.clientID"
    value = azurerm_user_assigned_identity.alb_controller.client_id
  }
}
```

### Step 3 — Define Gateway + HTTPRoutes

```yaml
# templates/agc-gateway.yaml.tftpl
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agc-gateway
  namespace: demo-apis
  annotations:
    alb.networking.azure.io/alb-id: <AGC_RESOURCE_ID>
spec:
  gatewayClassName: azure-alb-external
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All      # Allow routes from any namespace
  addresses:
    - type: alb.networking.azure.io/alb-frontend
      value: <AGC_FRONTEND_NAME>
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: orders-route
  namespace: demo-apis
spec:
  parentRefs:
    - name: agc-gateway
      namespace: demo-apis
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /orders
      backendRefs:
        - name: api-orders
          port: 8080
```

### Step 4 — Configure APIM as the API Gateway

APIM runs in internal VNet mode to keep it private. App Gateway is the only entry point.

```hcl
# terraform/apim.tf
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
}

# Backend pointing to AGC
resource "azurerm_api_management_backend" "agc" {
  name                = "agc-backend"
  resource_group_name = azurerm_resource_group.main.name
  api_management_name = azurerm_api_management.main.name
  protocol            = "http"
  url                 = "http://${azurerm_application_load_balancer_frontend.main.fully_qualified_domain_name}"
}

# API definition
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
```

### Step 5 — Configure App Gateway (Public Entry Point)

App Gateway v2 with WAF provides TLS termination, path-based routing, and DDoS protection.

```hcl
# terraform/appgateway.tf — path routing for /api/*
url_path_map {
  name                               = "path-map"
  default_backend_address_pool_name  = "pool-main"
  default_backend_http_settings_name = "settings-main"

  path_rule {
    name                       = "api-rule"
    paths                      = ["/api", "/api/*"]
    backend_address_pool_name  = "pool-apim"
    backend_http_settings_name = "settings-apim"
  }
}
```

### Step 6 — Validate

```powershell
# Test the full chain: App Gateway → APIM → AGC → Pod
curl -k "https://<APP_GW_IP>.sslip.io/api/agc/orders"

# Expected response:
# {
#   "service": "orders",
#   "cluster": "cluster1-agc",
#   "ingress": "agc",
#   "data": [...]
# }
```

---

## Scenario B — Frontend on AKS (App Gateway → APIM → AGC → NGINX Ingress → pod)

**Use case:** Serve static HTML/JS/CSS from an NGINX container on AKS instead of Azure Storage. The NGINX Ingress Controller handles the internal routing while AGC provides the external-facing L7 entry point that APIM can reach.

### Why NGINX Ingress for the frontend?

- NGINX Ingress is already deployed for legacy services — reuse the same controller
- Standard Kubernetes Ingress resources, no Gateway API CRDs needed for app teams
- NGINX Ingress handles path rewriting, headers, and other L7 features internally
- AGC acts as the bridge between APIM and the NGINX Ingress Controller

### Why not App Gateway → NGINX ILB directly?

Azure Standard Internal Load Balancers have cross-subnet connectivity limitations with App Gateway probes. Routing through APIM → AGC → NGINX Ingress avoids this while keeping the architecture clean.

### Traffic Flow

```
Browser
  │ HTTPS
  ▼
App Gateway (WAF_v2)
  │ Path: /aks-app/*
  │ Backend: APIM (internal)
  ▼
APIM (Internal VNet)
  │ API: aks-app → AGC frontend
  ▼
AGC (App Gateway for Containers)
  │ HTTPRoute: /aks-app → ingress-nginx-controller
  ▼
NGINX Ingress Controller (AKS Cluster 1)
  │ Ingress rule: /aks-app → frontend service
  │ Rewrite: strip /aks-app prefix
  ▼
NGINX Pod (AKS Cluster 1)
  │ Serves static HTML from ConfigMap
  ▼
Browser renders HTML
  │ API calls → /api/* → APIM (separate path)
```

### Step 1 — Create the NGINX Frontend Deployment

The static files are stored in a ConfigMap and mounted into the NGINX container.

```hcl
# terraform/k8s-cluster1.tf

resource "kubernetes_namespace_v1" "frontend" {
  provider = kubernetes.cluster1
  metadata { name = "frontend" }
}

resource "kubernetes_config_map_v1" "frontend_html" {
  provider = kubernetes.cluster1
  metadata {
    name      = "frontend-html"
    namespace = kubernetes_namespace_v1.frontend.metadata[0].name
  }
  data = {
    "index.html" = templatefile("${path.module}/templates/aks-frontend.html.tftpl", {
      client_id = azuread_application.main.client_id
      tenant_id = data.azurerm_client_config.current.tenant_id
      base_url  = "https://${local.hostname}"
    })
  }
}

resource "kubernetes_deployment_v1" "frontend" {
  provider = kubernetes.cluster1
  metadata {
    name      = "frontend"
    namespace = kubernetes_namespace_v1.frontend.metadata[0].name
    labels    = { app = "frontend" }
  }
  spec {
    replicas = 2
    selector { match_labels = { app = "frontend" } }
    template {
      metadata { labels = { app = "frontend" } }
      spec {
        container {
          name  = "nginx"
          image = "nginx:1.27-alpine"
          port  { container_port = 80 }
          volume_mount {
            name       = "html"
            mount_path = "/usr/share/nginx/html"
            read_only  = true
          }
        }
        volume {
          name = "html"
          config_map { name = kubernetes_config_map_v1.frontend_html.metadata[0].name }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "frontend" {
  provider = kubernetes.cluster1
  metadata {
    name      = "frontend"
    namespace = kubernetes_namespace_v1.frontend.metadata[0].name
  }
  spec {
    selector = { app = "frontend" }
    port { port = 80; target_port = 80 }
    type = "ClusterIP"
  }
}
```

### Step 2 — Add the NGINX Ingress for the Frontend

The NGINX Ingress Controller is already deployed on Cluster 1 (for legacy services). We add an Ingress resource in the `frontend` namespace pointing to the same `nginx` ingress class.

```hcl
# terraform/k8s-cluster1.tf
resource "kubernetes_ingress_v1" "nginx_frontend" {
  provider = kubernetes.cluster1

  metadata {
    name      = "ingress-frontend"
    namespace = kubernetes_namespace_v1.frontend.metadata[0].name
    annotations = {
      "nginx.ingress.kubernetes.io/rewrite-target" = "/$2"
    }
  }

  spec {
    ingress_class_name = "nginx"

    rule {
      http {
        path {
          path      = "/aks-app(/|$)(.*)"
          path_type = "ImplementationSpecific"
          backend {
            service {
              name = "frontend"
              port { number = 80 }
            }
          }
        }
      }
    }
  }
}
```

### Step 3 — Route App Gateway → APIM → AGC → NGINX Ingress

The path `/aks-app` is routed through APIM to AGC, which forwards to the NGINX Ingress Controller service.

```hcl
# terraform/appgateway.tf — path rule in url_path_map
path_rule {
  name                       = "aks-app-rule"
  paths                      = ["/aks-app", "/aks-app/*"]
  backend_address_pool_name  = "pool-apim"
  backend_http_settings_name = "settings-apim"
}
```

AGC HTTPRoute forwards `/aks-app` to the NGINX Ingress Controller:

```yaml
# templates/agc-gateway.yaml.tftpl
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: nginx-frontend-route
  namespace: ingress-nginx
spec:
  parentRefs:
    - name: agc-gateway
      namespace: demo-apis
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /aks-app
      backendRefs:
        - name: ingress-nginx-controller
          port: 80
```

### Step 4 — Validate

```powershell
# Fetch the AKS-hosted frontend page
curl -k "https://<APP_GW_IP>.sslip.io/aks-app"

# You should see the HTML page served by the NGINX pod
# The page can still call APIs through /api/* → APIM
```

### Decision: When to Put Frontend Through APIM?

| Criteria                          | Bypass APIM (recommended) | Through APIM      |
| --------------------------------- | ------------------------- | -------------------|
| Static HTML/CSS/JS                | ✅ No policies needed      | ❌ Adds latency    |
| Need API-level rate limiting      | N/A                       | ✅                 |
| Need request/response transform   | N/A                       | ✅                 |
| SPA calling backend APIs          | APIs go through APIM      | ❌ Don't mix       |
| Server-side rendered app          | ✅ Route directly          | Only if it IS an API|

**Recommendation:** Route static frontends via NGINX Ingress (App Gateway → APIM → AGC → NGINX Ingress → Pod). Route API calls through APIM → AGC directly.

---

## Scenario C — AGC + NGINX Ingress Co-Existence on the Same Cluster

**Use case:** You have existing services using classic NGINX Ingress and want to adopt AGC for new services without migrating everything at once.

### Can They Co-Exist? Yes!

AGC and NGINX Ingress use **different controllers and different CRDs**:

| Aspect              | AGC                                | NGINX Ingress                   |
| ------------------- | ---------------------------------- | --------------------------------|
| API                 | Gateway API (`gateway.networking.k8s.io`) | Ingress API (`networking.k8s.io/v1`) |
| Controller          | ALB Controller (Azure)             | ingress-nginx controller        |
| Ingress Class       | `azure-alb-external` (Gateway class) | `nginx` (Ingress class)       |
| Load Balancer       | AGC (Azure-managed, external)      | Internal Azure LB (ILB)        |
| Conflict?           | None — different API groups        | None — independent controller   |

### Traffic Flows

```
                    ┌──────────────────────────────────────────┐
                    │           AKS Cluster 1                  │
                    │                                          │
 AGC Frontend ─────►│ Gateway API ──► api-orders (port 8080)   │
 (Azure-managed)    │              ──► api-users  (port 8080)  │
                    │              ──► api-products (port 8080)│
                    │                                          │
 NGINX ILB ────────►│ Ingress     ──► legacy-app  (port 8080)  │
 (10.0.16.100)      │ (class=nginx)──► frontend    (port 80)   │
                    └──────────────────────────────────────────┘
```

### Step 1 — Install NGINX Ingress Controller

```hcl
# terraform/k8s-cluster1.tf — NGINX alongside AGC
resource "helm_release" "nginx_ingress_cluster1" {
  provider         = helm.cluster1
  name             = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"

  # Internal Azure Load Balancer
  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/azure-load-balancer-internal"
    value = "true"
    type  = "string"
  }

  # Static IP within the AKS1 subnet
  set {
    name  = "controller.service.loadBalancerIP"
    value = local.nginx_ilb_ip    # e.g., 10.0.16.100
  }

  # Explicit ingress class name — prevents conflict with AGC
  set {
    name  = "controller.ingressClassResource.name"
    value = "nginx"
  }

  set {
    name  = "controller.ingressClassResource.default"
    value = "false"     # Don't make NGINX the default — AGC handles new services
  }
}
```

### Step 2 — Deploy a Legacy Service with NGINX Ingress

```hcl
# Deployment
resource "kubernetes_deployment_v1" "nginx_legacy" {
  provider = kubernetes.cluster1
  metadata {
    name      = "legacy-app"
    namespace = kubernetes_namespace_v1.cluster1.metadata[0].name
    labels    = { app = "legacy-app" }
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "legacy-app" } }
    template {
      metadata { labels = { app = "legacy-app" } }
      spec {
        container {
          name  = "api"
          image = "${azurerm_container_registry.main.login_server}/demo-api:latest"
          port  { container_port = 8080 }
          env { name = "SERVICE_NAME"; value = "legacy" }
          env { name = "INGRESS_TYPE"; value = "nginx" }
        }
      }
    }
  }
}

# ClusterIP Service
resource "kubernetes_service_v1" "nginx_legacy" {
  provider = kubernetes.cluster1
  metadata {
    name      = "legacy-app"
    namespace = kubernetes_namespace_v1.cluster1.metadata[0].name
  }
  spec {
    selector = { app = "legacy-app" }
    port { port = 8080; target_port = 8080 }
    type = "ClusterIP"
  }
}

# Ingress (uses class "nginx", not AGC)
resource "kubernetes_ingress_v1" "nginx_legacy" {
  provider = kubernetes.cluster1
  metadata {
    name      = "ingress-legacy"
    namespace = kubernetes_namespace_v1.cluster1.metadata[0].name
    annotations = {
      "nginx.ingress.kubernetes.io/rewrite-target" = "/$2"
    }
  }
  spec {
    ingress_class_name = "nginx"    # <-- Key: explicit class
    rule {
      http {
        path {
          path      = "/legacy(/|$)(.*)"
          path_type = "ImplementationSpecific"
          backend {
            service {
              name = "legacy-app"
              port { number = 8080 }
            }
          }
        }
      }
    }
  }
}
```

### Step 3 — Route Options for Legacy Traffic

You have two choices for how external traffic reaches the NGINX ILB:

**Option 1: App Gateway → NGINX ILB (direct, no APIM)**

Best for legacy services that don't need API management policies.

```hcl
# terraform/appgateway.tf
backend_address_pool {
  name         = "pool-nginx"
  ip_addresses = [local.nginx_ilb_ip]
}

backend_http_settings {
  name                  = "settings-nginx"
  cookie_based_affinity = "Disabled"
  port                  = 80
  protocol              = "Http"
  request_timeout       = 30
}

path_rule {
  name                       = "legacy-direct-rule"
  paths                      = ["/legacy", "/legacy/*"]
  backend_address_pool_name  = "pool-nginx"
  backend_http_settings_name = "settings-nginx"
}
```

**Option 2: App Gateway → APIM → NGINX ILB**

Best when you want APIM policies (rate limiting, JWT validation, logging) on legacy APIs too.

```hcl
# terraform/apim.tf
resource "azurerm_api_management_backend" "nginx" {
  name                = "nginx-backend"
  resource_group_name = azurerm_resource_group.main.name
  api_management_name = azurerm_api_management.main.name
  protocol            = "http"
  url                 = "http://${local.nginx_ilb_ip}"
}

resource "azurerm_api_management_api" "nginx" {
  name                  = "nginx-apis"
  resource_group_name   = azurerm_resource_group.main.name
  api_management_name   = azurerm_api_management.main.name
  revision              = "1"
  display_name          = "APIs via NGINX (Cluster 1 — Legacy)"
  path                  = "api/nginx"
  protocols             = ["https", "http"]
  subscription_required = false
  service_url           = "http://${local.nginx_ilb_ip}"
}
```

Then call via: `https://<hostname>/api/nginx/legacy`

### Step 4 — Validate Co-Existence

```powershell
# Get cluster credentials
az aks get-credentials -g <RG> -n <AKS1_NAME> --admin

# Verify both controllers are running
kubectl get pods -n azure-alb-system   # AGC controller
kubectl get pods -n ingress-nginx      # NGINX controller

# Verify both ingress classes exist
kubectl get ingressclass
# NAME    CONTROLLER                             PARAMETERS
# nginx   k8s.io/ingress-nginx                   <none>
# (AGC uses GatewayClass, not IngressClass)

kubectl get gatewayclass
# NAME                  CONTROLLER                           ...
# azure-alb-external    alb.networking.azure.io/alb-controller

# Test AGC-routed service
curl -k "https://<APP_GW_IP>.sslip.io/api/agc/orders"

# Test NGINX-routed legacy service (direct)
curl -k "https://<APP_GW_IP>.sslip.io/legacy"

# Test NGINX-routed legacy service (through APIM)
curl -k "https://<APP_GW_IP>.sslip.io/api/nginx/legacy"
```

---

## Terraform Reference

### File Map

| File                            | What It Creates                                        |
| ------------------------------- | ------------------------------------------------------ |
| `main.tf`                       | Providers, locals, resource group                      |
| `variables.tf`                  | Input variables                                        |
| `network.tf`                    | VNet, subnets, NSGs                                    |
| `aks.tf`                        | AKS clusters, identities, ACR pull roles               |
| `agc.tf`                        | App Gateway for Containers, ALB controller identity     |
| `apim.tf`                       | APIM instance, backends (AGC, Traefik, NGINX), APIs    |
| `appgateway.tf`                 | App Gateway v2 WAF, backend pools, path routing         |
| `k8s-cluster1.tf`              | Cluster 1 workloads: ALB controller, APIs, NGINX ingress, legacy app, frontend |
| `k8s-cluster2.tf`              | Cluster 2 workloads: Traefik, APIs                      |
| `storage.tf`                    | Storage accounts for static websites                    |
| `entra.tf`                      | Entra ID app registration                               |
| `dns.tf`                        | Private DNS zones                                       |
| `frontend.tf`                   | HTML uploads to storage accounts                        |
| `outputs.tf`                    | Key outputs for scripting                               |
| `templates/agc-gateway.yaml.tftpl` | Gateway API + HTTPRoute manifests                   |
| `templates/aks-frontend.html.tftpl` | AKS-hosted frontend HTML template                   |

### Key Locals

```hcl
locals {
  suffix         = random_string.suffix.result
  hostname       = "${azurerm_public_ip.appgw.ip_address}.sslip.io"
  traefik_ilb_ip = cidrhost(var.subnet_cidrs["aks2"], 100)  # 10.0.20.100
  nginx_ilb_ip   = cidrhost(var.subnet_cidrs["aks1"], 100)  # 10.0.16.100
}
```

---

## Deployment

### Full Deployment

```powershell
cd sso-demo-auth-api

# 1. Login to Azure
az login --tenant <TENANT_ID>

# 2. Run the deployment script
.\scripts\deploy.ps1
```

The script will:
1. `terraform init` + `plan` + `apply` — create all Azure resources
2. `az acr build` — build and push the API container image
3. Restart AKS deployments to pick up the new image

### Manual Step-by-Step

```powershell
cd terraform

# Initialize
terraform init -upgrade

# Plan (review changes)
terraform plan -out=tfplan

# Apply
terraform apply tfplan

# Build container image
az acr build --registry $(terraform output -raw acr_login_server | % { ($_ -split '\.')[0] }) --image demo-api:latest ../apis/

# Apply Gateway API resources to Cluster 1
az aks get-credentials -g $(terraform output -raw resource_group) -n $(terraform output -raw aks1_name) --admin
kubectl apply -f .generated/agc-gateway.yaml

# Restart pods
kubectl rollout restart deployment -n demo-apis
kubectl rollout restart deployment -n frontend
```

---

## Validation & Testing

### Complete Test Matrix

```powershell
$ip = terraform output -raw app_gateway_public_ip
$base = "https://$ip.sslip.io"

# ── Scenario A: App Gateway → APIM → AGC → AKS ──
Write-Host "--- Scenario A: API via AGC ---"
curl -k "$base/api/agc/orders"
curl -k "$base/api/agc/users"
curl -k "$base/api/agc/products"

Write-Host "--- Scenario A: API via Traefik ---"
curl -k "$base/api/traefik/orders"

Write-Host "--- Scenario A: API via NGINX (through APIM) ---"
curl -k "$base/api/nginx/legacy"

# ── Scenario B: Frontend on AKS ──
Write-Host "--- Scenario B: AKS Frontend ---"
curl -k "$base/aks-app"

# ── Scenario C: Legacy via NGINX (direct) ──
Write-Host "--- Scenario C: Legacy direct ---"
curl -k "$base/legacy"

# ── Storage-hosted frontends (existing) ──
Write-Host "--- Storage frontends ---"
curl -k "$base/"
curl -k "$base/app1/"
```

---

## FAQ

### Q: Does AGC conflict with NGINX Ingress on the same cluster?

**No.** They use completely different Kubernetes API groups:
- AGC: `gateway.networking.k8s.io` (Gateway API) — managed by ALB Controller
- NGINX: `networking.k8s.io/v1` (Ingress API) — managed by ingress-nginx controller

Each controller only watches resources matching its own class. They don't interfere.

### Q: Should my AKS-hosted frontend go through APIM?

**No for static content.** APIM adds latency and is designed for API-level policies. Static HTML/CSS/JS should go directly from App Gateway through AGC to the pod. API calls from the frontend still go through APIM via `/api/*` paths.

### Q: Can I use AGC without App Gateway in front?

**Yes.** AGC has its own public frontend FQDN. You can expose services directly via AGC. However, App Gateway WAF adds TLS termination, WAF protection, and a unified entry point for both APIs and static content.

### Q: What's the cost difference between AGC and NGINX Ingress?

- **AGC**: Azure-managed, pay-per-use, no infrastructure to maintain. Higher cost but zero ops.
- **NGINX Ingress**: Free OSS, runs on your AKS nodes. You manage upgrades and scaling.
- **Recommendation**: Use AGC for new services, keep NGINX for existing legacy workloads, migrate gradually.

### Q: How do I migrate from NGINX Ingress to AGC?

1. Install ALB Controller on the cluster (already done in this setup)
2. Create Gateway + HTTPRoute for the service
3. Update APIM/App Gateway backends to point to AGC frontend
4. Remove the old NGINX Ingress resource
5. Once all services migrated, uninstall NGINX Ingress controller
