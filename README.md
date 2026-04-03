# SSO Demo — Multi-App Authentication with Azure

End-to-end Single Sign-On demo: multiple frontends (Azure Storage + AKS) sharing one hostname, backend APIs on AKS with AGC and NGINX Ingress co-existing, all fronted by Application Gateway WAF + APIM. Fully deployed with Terraform.

---

## Architecture

```
                          Internet
                             │
                             ▼
              ┌──────────────────────────────────┐
              │   Application Gateway v2 (WAF)   │
              │   Public IP — sslip.io hostname   │
              │   Self-signed TLS (demo)          │
              │──────────────────────────────────│
              │  Path-based routing:              │
              │   /          → Storage (Main)     │
              │   /app1/*    → Storage (Orders)   │
              │   /app2/*    → Storage (Users)    │
              │   /app3/*    → Storage (Products) │
              │   /aks-app/* → AGC (AKS frontend) │
              │   /api/*     → APIM (APIs)        │
              └──────┬──────────┬─────────┬───────┘
                     │          │         │
          Private    │          │         │  Private
          Endpoints  │   Direct │         │  VNet
                     ▼          ▼         ▼
         ┌──────────────┐  ┌────────┐  ┌─────────────┐
         │ 4× Storage   │  │  AGC   │  │    APIM     │
         │ Accounts     │  │        │  │  Developer  │
         │ (static web) │  │        │  │ Internal VNet│
         │ No public    │  │        │  └──┬──────┬───┘
         │ access       │  │        │     │      │
         └──────────────┘  │        │     │      │
                           │        │     │      │
                  /aks-app  │  /api/agc   │  /api/nginx
                           │        │     │      │
                           ▼        ▼     │      ▼
                    ┌──────────────────────┼──────────────────┐
                    │       AKS Cluster    │                  │
                    │                      │                  │
                    │  ┌─────────────┐     │  ┌────────────┐ │
                    │  │ NGINX Pod   │     │  │ NGINX      │ │
                    │  │ (frontend)  │     │  │ Ingress    │ │
                    │  └─────────────┘     │  │ ILB        │ │
                    │                      │  └─────┬──────┘ │
                    │  ┌─────┐ ┌──────┐   │  ┌─────┴──────┐ │
                    │  │Order│ │Users │◄──┘  │ Legacy APIs │ │
                    │  └─────┘ └──────┘      └────────────┘ │
                    │  ┌────────┐                            │
                    │  │Products│   ← AGC HTTPRoute          │
                    │  └────────┘                            │
                    └────────────────────────────────────────┘
```

### Traffic Routing

| Path | Route | Why |
|------|-------|-----|
| `/`, `/app1/*`, `/app2/*`, `/app3/*` | App Gateway → Private Endpoint → Storage | Static SPA files, no API layer needed |
| `/aks-app/*` | App Gateway → AGC → NGINX Pod | Static frontend on AKS — bypasses APIM (no benefit for static content) |
| `/api/agc/*` | App Gateway → APIM → AGC → API Pod | New APIs — APIM adds rate limiting, JWT validation, CORS |
| `/api/nginx/*` | App Gateway → APIM → NGINX Ingress → Pod | Legacy APIs on existing NGINX Ingress |

> See [docs/routing-scenarios.md](docs/routing-scenarios.md) for detailed traffic flow diagrams and Terraform references.

---

## SSO — How It Works

All frontends (Storage-hosted + AKS-hosted) share the **same hostname** via App Gateway path-based routing:

```
https://<public-ip>.sslip.io/       → Main Portal (Storage)
https://<public-ip>.sslip.io/app1/  → Orders App  (Storage)
https://<public-ip>.sslip.io/app2/  → Users App   (Storage)
https://<public-ip>.sslip.io/app3/  → Products App (Storage)
https://<public-ip>.sslip.io/aks-app/ → AKS Frontend (NGINX Pod)
```

**Why SSO works without additional sign-in:**
1. All apps share the same **origin** (`https://<ip>.sslip.io`)
2. MSAL.js stores tokens in `localStorage`, scoped by origin
3. User signs in on Main Portal → MSAL caches tokens
4. User navigates to any sub-app → MSAL finds cached tokens → **no re-auth**

### MSAL.js Configuration

```javascript
const msalConfig = {
    auth: {
        clientId: "<entra-app-client-id>",
        authority: "https://login.microsoftonline.com/<tenant-id>",
        redirectUri: "https://<hostname>/<app-path>/"
    },
    cache: {
        cacheLocation: "localStorage",    // Critical for SSO across paths
        storeAuthStateInCookie: true
    }
};
```

---

## Entra ID App Registration

Created automatically via Terraform (`terraform/entra.tf`):

| Setting | Value |
|---------|-------|
| **Display Name** | `sso-demo-auth-api-spa` |
| **Platform** | Single-Page Application (SPA) |
| **Auth Flow** | Authorization Code + PKCE (no client secret) |
| **Redirect URIs** | `/`, `/app1/`, `/app2/`, `/app3/`, `/aks-app/` |
| **Token Version** | v2.0 |
| **API Permissions** | `User.Read`, `openid`, `profile` |
| **Exposed API** | `api.access` scope for backend tokens |

### Manual Steps (post `terraform apply`)

> Some tenants restrict programmatic updates to app registrations. These must be set via Azure Portal.

**1. Enable Group Claims** — App registrations → `sso-demo-auth-api-spa` → Token configuration → Add groups claim → Security groups → Group ID for both ID and Access tokens

**2. Add Optional Claims** — Token configuration → Add optional claim → email for both ID and Access tokens

**3. Define App Roles** — App roles → Create: `Admin`, `Reader`, `User` (all for Users/Groups)

**4. Assign Roles** — Enterprise Applications → `sso-demo-auth-api-spa` → Users and groups → Assign yourself the Admin role

**Alternative:** Edit the manifest directly using the JSON in `terraform/update-app.json`.

---

## JWT Token & Group Claims

Each frontend has a **"See My JWT Token"** button showing decoded `idTokenClaims`:
- `name`, `preferred_username`, `email`
- `groups`: Array of Entra security group Object IDs
- `roles`: Assigned app roles (e.g. `["Admin"]`)

---

## Managed Identities

Zero passwords/secrets — all service-to-service auth uses Managed Identities:

| Component | Identity Type | Purpose |
|-----------|--------------|---------|
| AKS Cluster | User-Assigned MI | Network Contributor, ACR Pull |
| ALB Controller | User-Assigned + Workload Identity | Manages AGC (federated from K8s SA) |
| Storage Accounts | Entra ID auth | `storage_use_azuread = true`, no shared keys |
| Frontend SPA | MSAL.js (PKCE) | No client secret |

---

## APIs on Kubernetes

Single Docker image (`apis/app.py`), differentiated by environment variables (`SERVICE_NAME`, `INGRESS_TYPE`):

| Endpoint | Description |
|----------|-------------|
| `GET /{service_name}` | Returns mock data |
| `GET /{service_name}/health` | Health check |

```
AKS Cluster:
  ├── api-orders    (ClusterIP:8080) ──┐
  ├── api-users     (ClusterIP:8080) ──┼── AGC HTTPRoute (new APIs)
  ├── api-products  (ClusterIP:8080) ──┘
  ├── legacy-app    (ClusterIP:8080) ──── NGINX Ingress (legacy)
  └── frontend      (ClusterIP:80)  ──── AGC HTTPRoute (AKS frontend)
```

---

## AGC vs NGINX Ingress

Both co-exist on the same cluster. Use AGC for new services, NGINX Ingress for legacy.

| Aspect | AGC (new services) | NGINX Ingress (legacy) |
|--------|---------------------|------------------------|
| K8s API | Gateway API | Ingress API |
| Controller | ALB Controller (Azure-managed) | ingress-nginx (self-managed) |
| Cost | AGC billing (Azure-managed) | Standard LB only |
| Use when | New services, Azure-native | Existing workloads |

> See [docs/routing-scenarios.md](docs/routing-scenarios.md) for co-existence details.

---

## Network Layout

| Subnet | CIDR | Purpose |
|--------|------|---------|
| `appgw` | `10.0.1.0/24` | Application Gateway v2 (WAF) |
| `pe` | `10.0.2.0/24` | Private Endpoints (storage) |
| `apim` | `10.0.3.0/24` | APIM (internal VNet) |
| `agc` | `10.0.4.0/24` | App Gateway for Containers |
| `aks1` | `10.0.16.0/22` | AKS Cluster (nodes + pods) |

---

## Prerequisites

- **Azure CLI** (`az`) — logged in
- **Terraform** ≥ 1.5
- **PowerShell** 7+ — for PFX cert generation
- **kubectl** — optional, for debugging
- **Permissions**: Contributor + User Access Administrator on subscription, Application Administrator in Entra ID

## Deployment

```powershell
.\scripts\deploy.ps1
```

Or manually:

```powershell
cd terraform
terraform init
terraform plan -out=tfplan
terraform apply tfplan
az acr build --registry $(terraform output -raw acr_login_server) --image demo-api:latest ../apis/
```

> APIM Developer tier takes ~30-45 min to provision. Self-signed TLS cert triggers browser warnings.

## Live URLs

| Endpoint | URL |
|----------|-----|
| Main Portal | `https://<public-ip>.sslip.io/` |
| Orders App | `https://<public-ip>.sslip.io/app1/` |
| Users App | `https://<public-ip>.sslip.io/app2/` |
| Products App | `https://<public-ip>.sslip.io/app3/` |
| AKS Frontend | `https://<public-ip>.sslip.io/aks-app/` |
| API (AGC) | `https://<public-ip>.sslip.io/api/agc/orders/health` |
| API (NGINX) | `https://<public-ip>.sslip.io/api/nginx/legacy` |

## Testing

1. Open Main Portal → Sign In → See JWT Token (check `groups`, `roles`)
2. Navigate to `/app1/` → should show "SSO Active" with no sign-in
3. Navigate to `/aks-app/` → SSO works across Storage and AKS frontends
4. Test API health checks:

```bash
curl -k https://<public-ip>.sslip.io/api/agc/orders/health
curl -k https://<public-ip>.sslip.io/api/agc/users/health
curl -k https://<public-ip>.sslip.io/api/nginx/legacy
```

## Tear Down

```powershell
cd terraform
terraform destroy -auto-approve
```

---

## Project Structure

```
├── README.md
├── apis/
│   ├── app.py              # Flask API (single image, 3 services via env var)
│   ├── Dockerfile
│   └── requirements.txt
├── docs/
│   └── routing-scenarios.md # Detailed routing architecture & Terraform reference
├── scripts/
│   └── deploy.ps1           # One-command deployment
└── terraform/
    ├── main.tf              # Providers, locals, resource group
    ├── variables.tf         # Input variables
    ├── network.tf           # VNet + subnets + NSGs
    ├── storage.tf           # Storage accounts + static websites + PEs
    ├── dns.tf               # Private DNS zones
    ├── acr.tf               # Container registry
    ├── entra.tf             # Entra ID app registration
    ├── appgateway.tf        # App Gateway v2 WAF, path routing
    ├── apim.tf              # APIM (internal VNet), API definitions
    ├── aks.tf               # AKS cluster + identities
    ├── agc.tf               # App Gateway for Containers + ALB identity
    ├── k8s-cluster1.tf      # ALB controller, deployments, NGINX ingress, frontend
    ├── frontend.tf          # HTML uploads to storage
    ├── outputs.tf           # Key outputs
    └── templates/
        ├── main-portal.html.tftpl
        ├── sub-app.html.tftpl
        ├── aks-frontend.html.tftpl
        └── agc-gateway.yaml.tftpl
```
