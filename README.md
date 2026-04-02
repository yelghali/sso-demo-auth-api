# SSO Demo — Multi-App Authentication with Azure

End-to-end Single Sign-On demo: multiple React frontends sharing one hostname, backend APIs on two AKS clusters (comparing AGC vs Traefik ingress), all fronted by Application Gateway WAF + APIM. Fully deployed with Terraform.

---

## Table of Contents

- [Architecture](#architecture)
- [SSO — How It Works](#sso--how-it-works)
- [Entra ID App Registration](#entra-id-app-registration)
- [JWT Token & Group Claims](#jwt-token--group-claims)
- [Managed Identities & Authentication](#managed-identities--authentication)
- [APIs on Kubernetes](#apis-on-kubernetes)
- [Two Ingress Strategies (Cost Comparison)](#two-ingress-strategies-cost-comparison)
- [Storage Network Security](#storage-network-security)
- [Network Layout](#network-layout)
- [Resource Inventory](#resource-inventory)
- [Prerequisites](#prerequisites)
- [Deployment](#deployment)
- [Live URLs](#live-urls)
- [Testing](#testing)
- [Tear Down](#tear-down)
- [Project Structure](#project-structure)

---

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

### Traffic Flow (end-to-end)

```
Browser → App Gateway (WAF, TLS termination)
     ├─ / , /app1/, /app2/, /app3/  → Private Endpoint → Storage Account (static HTML)
     └─ /api/*                      → APIM (internal VNet mode)
           ├─ /api/agc/*            → AGC Frontend → AKS Cluster 1 (Gateway API + HTTPRoute)
           └─ /api/traefik/*        → Internal LB → Traefik → AKS Cluster 2 (K8s Ingress)
```

**Internal pod-to-pod**: APIs within the same cluster communicate via ClusterIP services (no external routing needed).

---

## SSO — How It Works

All 4 frontends (main portal + 3 sub-apps) are served from the **same hostname** via App Gateway path-based routing:

```
https://<public-ip>.sslip.io/       → Main Portal
https://<public-ip>.sslip.io/app1/  → Orders App
https://<public-ip>.sslip.io/app2/  → Users App
https://<public-ip>.sslip.io/app3/  → Products App
```

**Why SSO works without additional sign-in:**

1. All apps share the same **origin** (`https://<ip>.sslip.io`).
2. MSAL.js stores tokens in `localStorage`, which is scoped by origin.
3. User signs in on the Main Portal → MSAL caches tokens in `localStorage`.
4. User navigates to `/app1/` → MSAL detects existing cached tokens → **no re-authentication needed**.
5. Sub-apps show "SSO Active" immediately and can call APIs with the cached access token.

### MSAL.js Configuration

Each frontend uses identical MSAL config (only `redirectUri` differs):

```javascript
const msalConfig = {
    auth: {
        clientId: "<entra-app-client-id>",
        authority: "https://login.microsoftonline.com/<tenant-id>",
        redirectUri: "https://<hostname>/<app-path>/"
    },
    cache: {
        cacheLocation: "localStorage",    // Critical for SSO across paths
        storeAuthStateInCookie: true       // Fallback for IE11/Edge
    }
};
```

### Auth Flow

```
1. User clicks "Sign In" on Main Portal
2. MSAL.js → loginRedirect() → Entra ID authorization endpoint
3. User authenticates (MFA if configured)
4. Entra ID redirects back to / with auth code
5. MSAL.js exchanges code for tokens (PKCE, no client secret needed)
6. ID token + access token cached in localStorage
7. User navigates to /app1/ → MSAL.js finds cached tokens → SSO!
```

---

## Entra ID App Registration

Created automatically via Terraform (`terraform/entra.tf`):

| Setting | Value |
|---------|-------|
| **Display Name** | `sso-demo-auth-api-spa` |
| **Platform** | Single-Page Application (SPA) |
| **Auth Flow** | Authorization Code + PKCE (no client secret) |
| **Redirect URIs** | `/`, `/app1/`, `/app2/`, `/app3/` |
| **Token Version** | v2.0 |
| **API Permissions** | `User.Read`, `openid`, `profile` |
| **Exposed API** | `api.access` scope for backend tokens |

### Required Manual Steps (post `terraform apply`)

> **Why manual?** Some tenants restrict programmatic (Graph API / CLI) updates to app registrations. Terraform creates the app but cannot modify certain manifest properties like `groupMembershipClaims` and `optionalClaims`. These must be set via the Azure Portal.

#### Step 1 — Enable Group Claims in Token Configuration

1. Go to **[Azure Portal](https://portal.azure.com)** → **Entra ID** → **App registrations** → **`sso-demo-auth-api-spa`**
2. Click **Token configuration** in the left menu
3. Click **+ Add groups claim**
4. Select **Security groups**
5. For both **ID** and **Access** token types, check:
   - ✅ Group ID
6. Click **Add**

#### Step 2 — Add Optional Claims (email)

1. Still in **Token configuration**, click **+ Add optional claim**
2. Select **Token type: ID**
3. Check **email** → Click **Add**
4. Repeat for **Token type: Access** → check **email** → **Add**

#### Step 3 — Define App Roles

1. Go to **App roles** in the left menu
2. Click **+ Create app role** three times:

| Display Name | Value | Allowed members | Description |
|-------------|-------|-----------------|-------------|
| Admin | `Admin` | Users/Groups | Full access to all demo resources |
| Reader | `Reader` | Users/Groups | Read-only access to demo resources |
| User | `User` | Users/Groups | Standard user access |

#### Step 4 — Assign Roles to Users

1. Go to **Enterprise Applications** → **`sso-demo-auth-api-spa`**
2. Click **Users and groups** → **+ Add user/group**
3. Select yourself and assign the **Admin** role
4. Click **Assign**

#### Step 5 — (Alternative) Edit Manifest Directly

Instead of steps 1-3, you can edit the manifest JSON directly:

1. Go to **App registrations** → **`sso-demo-auth-api-spa`** → **Manifest**
2. Find and replace/add these properties (see `terraform/update-app.json` for the full JSON):

```json
"groupMembershipClaims": "SecurityGroup",
"optionalClaims": {
    "idToken": [
        {"name": "groups", "essential": false, "additionalProperties": ["sam_account_name", "cloud_displayname"]},
        {"name": "email", "essential": true, "additionalProperties": []}
    ],
    "accessToken": [
        {"name": "groups", "essential": false, "additionalProperties": ["sam_account_name", "cloud_displayname"]},
        {"name": "email", "essential": true, "additionalProperties": []}
    ]
},
"appRoles": [
    {"id": "00000000-0000-0000-0000-000000000010", "allowedMemberTypes": ["User"], "displayName": "Admin", "value": "Admin", "isEnabled": true, "description": "Full access"},
    {"id": "00000000-0000-0000-0000-000000000011", "allowedMemberTypes": ["User"], "displayName": "Reader", "value": "Reader", "isEnabled": true, "description": "Read-only"},
    {"id": "00000000-0000-0000-0000-000000000012", "allowedMemberTypes": ["User"], "displayName": "User", "value": "User", "isEnabled": true, "description": "Standard access"}
]
```

3. Click **Save**

#### Step 6 — Verify

1. Sign out and sign back in on the portal
2. Click **See My JWT Token** — you should now see:
   - `groups`: array of security group Object IDs
   - `roles`: array of assigned app role values (e.g. `["Admin"]`)

---

## JWT Token & Group Claims

Each frontend has a **"See My JWT Token"** button that shows:

- **Decoded tab**: The full `idTokenClaims` JSON, including:
  - `name`, `preferred_username`, `email`
  - `groups`: Array of Entra security group **Object IDs** the user belongs to
  - `aud`, `iss`, `iat`, `exp` (standard JWT claims)
- **Raw tab**: The base64-encoded JWT string

### Enabling Group Claims

The Terraform `entra.tf` configures:

```hcl
group_membership_claims = ["SecurityGroup"]

optional_claims {
  id_token {
    name                  = "groups"
    additional_properties = ["emit_as_roles"]
  }
  access_token {
    name                  = "groups"
    additional_properties = ["emit_as_roles"]
  }
}
```

This means:
- The **ID token** will contain `groups: ["<group-object-id-1>", "<group-object-id-2>"]`
- The **Access token** will contain the same, usable by backend APIs
- Groups are also emitted as `roles` for easy RBAC in backend APIs
- If a user belongs to >200 groups, Entra returns a `_claim_names`/`_claim_sources` overage indicator instead — the app must call Microsoft Graph to get full list

---

## Managed Identities & Authentication

This project uses **zero passwords/secrets** for Azure service-to-service auth via Managed Identities:

| Component | Identity Type | Purpose |
|-----------|--------------|---------|
| **AKS Cluster 1** | User-Assigned Managed Identity | Network Contributor on its subnet, ACR Pull |
| **AKS Cluster 2** | User-Assigned Managed Identity | Network Contributor on its subnet, ACR Pull |
| **ALB Controller** | User-Assigned + Workload Identity | Manages AGC configuration (federated from K8s SA) |
| **AKS Kubelet** | System-Assigned | Pulls images from ACR |
| **Storage Accounts** | Entra ID (azurerm provider) | No shared access keys — data plane uses `storage_use_azuread = true` |
| **Frontend SPA** | MSAL.js (PKCE) | No client secret — auth code + PKCE flow |

### Workload Identity (ALB Controller)

The ALB Controller in AKS Cluster 1 uses **Workload Identity Federation** — it exchanges a K8s service account token for an Azure AD token without any stored credential:

```
K8s Service Account (azure-alb-system:alb-controller-sa)
    ↓ Federated Identity Credential
Azure User-Assigned Managed Identity (alb-controller-id)
    ↓ RBAC
AppGw for Containers Configuration Manager (on AGC resource)
Network Contributor (on AGC subnet)
Reader (on Resource Group)
```

### Storage Data Plane Auth

Storage accounts have `shared_access_key_enabled = false` — enforced by tenant policy. The Terraform azurerm provider uses the deploying user's Entra identity (via `storage_use_azuread = true` in the provider config) with a `Storage Blob Data Contributor` role assignment.

---

## APIs on Kubernetes

### Single Container Image, Three Services

All APIs use the same Docker image (`apis/app.py`), differentiated by environment variables:

```yaml
env:
  - name: SERVICE_NAME    # orders | users | products
  - name: CLUSTER_NAME    # cluster1-agc | cluster2-traefik
  - name: INGRESS_TYPE    # agc | traefik
```

The Flask app returns mock data based on `SERVICE_NAME`:

| Endpoint | Description |
|----------|-------------|
| `GET /` or `GET /{service_name}` | Returns mock data for the service |
| `GET /health` or `GET /{service_name}/health` | Health check |
| `GET /{service_name}/<subpath>` | Catch-all for path-based routing |

### Deployment Topology

Each AKS cluster runs 3 deployments (1 replica each):

```
AKS Cluster 1 (Azure CNI, VNet-routable pods):
  ├── api-orders    (ClusterIP:8080) ──┐
  ├── api-users     (ClusterIP:8080) ──┼── AGC HTTPRoute → /orders, /users, /products
  └── api-products  (ClusterIP:8080) ──┘

AKS Cluster 2 (CNI Overlay):
  ├── api-orders    (ClusterIP:8080) ──┐
  ├── api-users     (ClusterIP:8080) ──┼── Traefik Ingress → /orders, /users, /products
  └── api-products  (ClusterIP:8080) ──┘
```

---

## Two Ingress Strategies (Cost Comparison)

| Aspect | Cluster 1 — AGC | Cluster 2 — Traefik |
|--------|-----------------|---------------------|
| **Ingress Controller** | App Gateway for Containers (ALB Controller) | Traefik (Helm chart) |
| **Load Balancer** | Managed by Azure (AGC) | Internal Azure LB |
| **K8s API** | Gateway API (`Gateway` + `HTTPRoute`) | Kubernetes Ingress |
| **Network Plugin** | Azure CNI (pods get VNet IPs) | Azure CNI Overlay (pods get overlay IPs) |
| **Extra Azure Cost** | AGC resource billing | Standard LB only |
| **Setup Complexity** | Higher (Workload Identity + RBAC + Gateway API CRDs) | Lower (Helm install + Ingress resource) |
| **TLS Termination** | At AGC level | At Traefik level |
| **Why Choose** | Azure-native, auto-scaling, no self-managed controller | Full control, open-source, portable across clouds |

---

## Storage Network Security

Static website endpoints (`*.z20.web.core.windows.net`) are **blocked from public internet** — only accessible through App Gateway via Private Endpoints.

| Layer | What It Does |
|-------|-------------|
| `network_rules { default_action = "Deny" }` | Blocks all public access to the storage account, including the static website endpoint |
| Private Endpoints (`web` sub-resource) | App Gateway reaches storage content through the VNet — PEs bypass the firewall |
| Deployer IP in `ip_rules` | Auto-detected via `api.ipify.org` so Terraform can still upload HTML blobs |
| `shared_access_key_enabled = false` | Enforced by tenant policy — data plane uses Entra ID auth (`storage_use_azuread = true`) |

```
Public internet → *.z20.web.core.windows.net   ❌  403 Forbidden (firewall)
App Gateway     → Private Endpoint (VNet)       ✅  200 OK
Terraform CLI   → Deployer IP allow-listed       ✅  Upload blobs
```

> **Note:** Azure Storage firewall rules (IP + VNet) apply to the static website endpoint (`$web`), unlike `allow_blob_public_access` and container ACLs which do **not** affect it.

---

## Network Layout

| Subnet | CIDR | Purpose |
|--------|------|---------|
| `appgw` | `10.0.1.0/24` | Application Gateway v2 (WAF) |
| `pe` | `10.0.2.0/24` | Private Endpoints (4× storage web) |
| `apim` | `10.0.3.0/24` | API Management (internal VNet) |
| `agc` | `10.0.4.0/24` | App Gateway for Containers |
| `aks1` | `10.0.16.0/22` | AKS Cluster 1 (nodes + VNet-routable pods) |
| `aks2` | `10.0.20.0/22` | AKS Cluster 2 (nodes only, pods use overlay) |

**Private DNS Zones:**
- `privatelink.web.core.windows.net` — resolves storage private endpoints
- `azure-api.net` — resolves APIM internal FQDN

---

## Resource Inventory

| Resource | Name/Count | SKU/Tier |
|----------|-----------|----------|
| Resource Group | `sso-demo-auth-api-rg` | — |
| VNet | 1 (6 subnets) | — |
| App Gateway v2 | 1 (WAF_v2) | Standard_v2 |
| WAF Policy | 1 (OWASP 3.2, Prevention mode) | — |
| Storage Accounts | 4 (static website, PE, no public) | Standard_LRS |
| Private Endpoints | 4 (storage web sub-resource) | — |
| APIM | 1 (internal VNet) | Developer × 1 unit |
| ACR | 1 | Basic |
| AKS | 2 clusters | Standard_D2s_v3 × 1 node each |
| AGC | 1 traffic controller | — |
| Entra App Registration | 1 (SPA, group claims) | — |
| Private DNS Zones | 2 (storage + APIM) | — |
| Managed Identities | 4 (AKS1, AKS2, ALB Controller, deployer role) | — |

---

## Prerequisites

- **Azure CLI** (`az`) — logged in to your tenant
- **Terraform** ≥ 1.5
- **PowerShell** 7+ (`pwsh`) — for PFX certificate generation
- **kubectl** — for debugging (optional)
- **Permissions**: Contributor + User Access Administrator on the subscription, Application Administrator in Entra ID

## Deployment

### One-Command Deploy

```powershell
.\scripts\deploy.ps1
```

### Manual Deploy

```powershell
cd terraform
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# Build and push the API container image
az acr build --registry $(terraform output -raw acr_login_server) --image demo-api:latest ../apis/
```

> **Note**: APIM Developer tier takes ~30-45 minutes to provision. The self-signed TLS cert will trigger a browser warning — expected for a demo.

## Live URLs

| Endpoint | URL |
|----------|-----|
| **Main Portal** | `https://20.119.248.71.sslip.io/` |
| **Orders App** | `https://20.119.248.71.sslip.io/app1/` |
| **Users App** | `https://20.119.248.71.sslip.io/app2/` |
| **Products App** | `https://20.119.248.71.sslip.io/app3/` |
| **API — AGC Orders** | `https://20.119.248.71.sslip.io/api/agc/orders/health` |
| **API — Traefik Users** | `https://20.119.248.71.sslip.io/api/traefik/users/health` |

> Self-signed cert triggers a browser warning — expected for the demo.

---

## Testing

### Frontend URLs

| App | URL |
|-----|-----|
| Main Portal | `https://<public-ip>.sslip.io/` |
| Orders App | `https://<public-ip>.sslip.io/app1/` |
| Users App | `https://<public-ip>.sslip.io/app2/` |
| Products App | `https://<public-ip>.sslip.io/app3/` |

### API Health Checks

```bash
# AGC path (Cluster 1)
curl -k https://<public-ip>.sslip.io/api/agc/orders/health
curl -k https://<public-ip>.sslip.io/api/agc/users/health
curl -k https://<public-ip>.sslip.io/api/agc/products/health

# Traefik path (Cluster 2)
curl -k https://<public-ip>.sslip.io/api/traefik/orders/health
curl -k https://<public-ip>.sslip.io/api/traefik/users/health
curl -k https://<public-ip>.sslip.io/api/traefik/products/health
```

### SSO Test Flow

1. Open the Main Portal and click **Sign In**
2. Authenticate with your Entra ID account
3. Click **See My JWT Token** — inspect the decoded claims including `groups`
4. Navigate to `/app1/` — you should see **"SSO Active"** with no sign-in prompt
5. Click **See My JWT Token** on the sub-app — same token, same groups
6. Call APIs from both clusters using the frontend buttons

## Tear Down

```powershell
cd terraform
terraform destroy -auto-approve
```

---

## Project Structure

```
├── README.md
├── .gitignore
├── apis/
│   ├── app.py              # Flask API (single image, 3 services via env var)
│   ├── Dockerfile           # Python 3.11-slim container
│   └── requirements.txt     # Flask + gunicorn
├── scripts/
│   └── deploy.ps1           # One-command deployment script
└── terraform/
    ├── main.tf              # Providers (azurerm, azuread, kubernetes×2, helm×2, tls)
    ├── variables.tf         # Input variables (prefix, region, CIDRs, AKS size)
    ├── terraform.tfvars     # Variable overrides
    ├── network.tf           # VNet + 6 subnets + NSGs
    ├── dns.tf               # Private DNS zones (storage + APIM)
    ├── storage.tf           # 4 storage accounts + static website + PEs
    ├── acr.tf               # Container registry
    ├── entra.tf             # Entra ID app registration (SPA, group claims)
    ├── appgateway.tf        # App Gateway v2 (WAF), path routing, self-signed TLS
    ├── apim.tf              # APIM Developer (internal VNet), CORS, API routing
    ├── aks.tf               # 2 AKS clusters (Azure CNI / CNI Overlay)
    ├── agc.tf               # App Gateway for Containers + ALB identity + RBAC
    ├── k8s-cluster1.tf      # Cluster 1: ALB controller Helm, deployments, Gateway API
    ├── k8s-cluster2.tf      # Cluster 2: Traefik Helm, deployments, K8s Ingress
    ├── frontend.tf          # Upload templated HTML to storage accounts
    ├── outputs.tf           # Key outputs (URLs, IPs, names)
    └── templates/
        ├── main-portal.html.tftpl  # Main portal HTML (MSAL.js + JWT viewer)
        ├── sub-app.html.tftpl      # Sub-app HTML template (SSO detection)
        └── agc-gateway.yaml.tftpl  # Gateway API resources for AGC
```


