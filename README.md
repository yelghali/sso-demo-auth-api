# SSO Demo — Multi-App Authentication with Azure

Single Sign-On across multiple frontend apps sharing one hostname, with backend APIs on two AKS clusters using different ingress strategies.

## Architecture

```
                          Internet
                             │
                             ▼
              ┌──────────────────────────────────┐
              │   Application Gateway v2 (WAF)   │
              │   Public IP ─ sslip.io hostname   │
              │   Self-signed TLS (demo)          │
              │──────────────────────────────────│
              │  Path-based routing:              │
              │   /          → Storage (Main)     │
              │   /app1/*    → Storage (Orders)   │
              │   /app2/*    → Storage (Users)    │
              │   /app3/*    → Storage (Products) │
              │   /api/*     → APIM (internal)    │
              └──────┬────────────┬───────────────┘
                     │            │
          Private    │            │  Private
          Endpoints  │            │  VNet
                     ▼            ▼
         ┌──────────────┐   ┌─────────────────┐
         │ 4× Storage   │   │     APIM        │
         │ Accounts     │   │   Developer     │
         │ (static web) │   │  Internal VNet  │
         │ No public    │   └───┬─────────┬───┘
         │ access       │       │         │
         └──────────────┘       │         │
                                │         │
                    /api/agc/*  │         │  /api/traefik/*
                                │         │
                                ▼         ▼
              ┌───────────────────┐  ┌───────────────────┐
              │    AGC            │  │  Internal LB      │
              │  (Gateway API)   │  │  + Traefik Ingress │
              └────────┬──────────┘  └────────┬──────────┘
                       │                      │
                       ▼                      ▼
              ┌───────────────────┐  ┌───────────────────┐
              │  AKS Cluster 1   │  │  AKS Cluster 2    │
              │  Azure CNI       │  │  CNI Overlay       │
              │  ┌─────┐┌──────┐ │  │  ┌─────┐┌──────┐  │
              │  │Order││Users │ │  │  │Order││Users │  │
              │  └─────┘└──────┘ │  │  └─────┘└──────┘  │
              │  ┌────────┐      │  │  ┌────────┐       │
              │  │Products│      │  │  │Products│       │
              │  └────────┘      │  │  └────────┘       │
              └───────────────────┘  └───────────────────┘
```

### SSO Flow

All frontends share the same hostname (via App Gateway). MSAL.js stores tokens in `localStorage`, which is scoped by origin. User signs in on the main portal → navigates to `/app1/`, `/app2/`, `/app3/` → MSAL detects existing tokens → no re-authentication needed.

### Two Ingress Strategies (Cost Comparison)

| Aspect | Cluster 1 — AGC | Cluster 2 — Traefik |
|--------|-----------------|---------------------|
| Ingress controller | App Gateway for Containers | Traefik (Helm) |
| Load balancer | Managed by Azure (AGC) | Internal Azure LB |
| K8s API | Gateway API (HTTPRoute) | Kubernetes Ingress |
| Network plugin | Azure CNI (VNet-routable pods) | Azure CNI Overlay |
| Azure resource | `Microsoft.ServiceNetworking` | Standard LB + Helm |

### Network Layout

| Subnet | CIDR | Purpose |
|--------|------|---------|
| `appgw` | `10.0.0.0/24` | Application Gateway v2 |
| `pe` | `10.0.1.0/24` | Private Endpoints (storage) |
| `apim` | `10.0.2.0/24` | API Management |
| `agc` | `10.0.4.0/24` | App Gateway for Containers |
| `aks1` | `10.0.16.0/22` | AKS Cluster 1 (nodes + pods) |
| `aks2` | `10.0.20.0/22` | AKS Cluster 2 (nodes) |

### Resource Inventory

| Resource | Name/Count | SKU/Tier |
|----------|-----------|----------|
| Resource Group | `sso-demo-auth-api-rg` | — |
| VNet | 1 (6 subnets) | — |
| App Gateway v2 | 1 (WAF_v2) | Standard_v2 |
| Storage Accounts | 4 (static website) | Standard_LRS |
| Private Endpoints | 4 (storage web) | — |
| APIM | 1 (internal VNet) | Developer_1 |
| ACR | 1 | Basic |
| AKS | 2 clusters | Standard_D2s_v3 × 1 node each |
| AGC | 1 traffic controller | — |
| Entra App Registration | 1 (SPA) | — |
| Private DNS Zones | 2 (storage + APIM) | — |

## Live URLs

| Endpoint | URL |
|----------|-----|
| Main Portal | `https://<app-gw-ip>.sslip.io/` |
| Orders App | `https://<app-gw-ip>.sslip.io/app1/` |
| Users App | `https://<app-gw-ip>.sslip.io/app2/` |
| Products App | `https://<app-gw-ip>.sslip.io/app3/` |
| APIs (AGC) | `https://<app-gw-ip>.sslip.io/api/agc/{orders,users,products}/health` |
| APIs (Traefik) | `https://<app-gw-ip>.sslip.io/api/traefik/{orders,users,products}/health` |

## Prerequisites

- Azure CLI (`az login --tenant <tenant-id>`)
- Terraform >= 1.5
- kubectl
- Subscription registered for `Microsoft.ServiceNetworking`

## Deploy

```powershell
# Option 1: Automated script
.\scripts\deploy.ps1

# Option 2: Manual
cd terraform
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# Build and push the API image
az acr build --registry <acr-name> --image demo-api:latest ../apis/

# Apply AGC Gateway API resources (after AKS is ready)
az aks get-credentials -g sso-demo-auth-api-rg -n <aks1-name> --admin
kubectl apply -f terraform/.generated/agc-gateway.yaml
```

## Destroy

```powershell
.\scripts\deploy.ps1 -DestroyAll
# or
cd terraform && terraform destroy
```

## Project Structure

```
terraform/                       # Infrastructure as Code
  main.tf                        # Providers (azurerm, azuread, kubernetes, helm, tls)
  variables.tf                   # Input variables
  terraform.tfvars               # Variable overrides
  network.tf                     # VNet, 6 subnets, NSGs
  dns.tf                         # Private DNS zones (storage, APIM)
  storage.tf                     # 4 storage accounts + PE + role assignments
  appgateway.tf                  # App Gateway v2 (WAF), path routing, URL rewrite
  apim.tf                        # APIM Developer (internal VNet), catch-all APIs
  acr.tf                         # Azure Container Registry
  aks.tf                         # 2 AKS clusters + ACR pull roles
  agc.tf                         # App Gateway for Containers + ALB identity
  entra.tf                       # Entra ID app registration (SPA)
  k8s-cluster1.tf                # Cluster 1: ALB controller, deployments, Gateway API
  k8s-cluster2.tf                # Cluster 2: Traefik Helm, deployments, Ingress
  frontend.tf                    # Upload templated HTML to storage blobs
  outputs.tf                     # Key outputs (URLs, IPs, names)
  templates/
    main-portal.html.tftpl       # Main SSO portal page
    sub-app.html.tftpl           # Sub-app template (Orders/Users/Products)
    agc-gateway.yaml.tftpl       # Gateway API resources for AGC
apis/
  app.py                         # Flask API (single image, SERVICE_NAME env var)
  Dockerfile                     # Container build
  requirements.txt               # Python dependencies
scripts/
  deploy.ps1                     # One-command deploy/destroy
```

## Notes

- APIM Developer tier takes ~30–45 min to provision
- Self-signed TLS certificate — accept browser warning for demo
- All storage accounts use Entra-only auth (no shared keys)
- Storage accounts are private (accessible only via Private Endpoints)
- AKS Cluster 1 uses Azure CNI (VNet-routable pods) required by AGC
- AKS Cluster 2 uses CNI Overlay (pods on virtual network, routed via Traefik ClusterIP)
