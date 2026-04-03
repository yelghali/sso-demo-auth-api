# ─── Entra ID (Azure AD) App Registration ───────────────────────

resource "azuread_application" "main" {
  display_name = "${var.prefix}-spa"

  # Emit ALL group types (Security + Microsoft 365 + Directory roles)
  group_membership_claims = ["All"]

  # SPA auth (MSAL.js) — redirect URIs use the App Gateway hostname
  single_page_application {
    redirect_uris = [
      "https://${local.hostname}/",
      "https://${local.hostname}/app1/",
      "https://${local.hostname}/app2/",
      "https://${local.hostname}/app3/",
      "https://${local.hostname}/aks-app/",
    ]
  }

  # ─── App Roles (appear in the `roles` claim) ────────────────
  app_role {
    allowed_member_types = ["User"]
    description          = "Full access to all demo resources"
    display_name         = "Admin"
    id                   = "00000000-0000-0000-0000-000000000010"
    enabled              = true
    value                = "Admin"
  }

  app_role {
    allowed_member_types = ["User"]
    description          = "Read-only access to demo resources"
    display_name         = "Reader"
    id                   = "00000000-0000-0000-0000-000000000011"
    enabled              = true
    value                = "Reader"
  }

  app_role {
    allowed_member_types = ["User"]
    description          = "Standard user access"
    display_name         = "User"
    id                   = "00000000-0000-0000-0000-000000000012"
    enabled              = true
    value                = "User"
  }

  # ─── Optional Claims (groups in `groups`, NOT as roles) ─────
  optional_claims {
    id_token {
      name = "groups"
    }
    id_token {
      name      = "email"
      essential = true
    }
    access_token {
      name = "groups"
    }
    access_token {
      name      = "email"
      essential = true
    }
  }

  # Expose an API scope for backend access
  api {
    mapped_claims_enabled          = true
    requested_access_token_version = 2

    oauth2_permission_scope {
      admin_consent_description  = "Access the SSO Demo APIs"
      admin_consent_display_name = "Access APIs"
      id                         = "00000000-0000-0000-0000-000000000001"
      enabled                    = true
      type                       = "User"
      user_consent_description   = "Access the SSO Demo APIs"
      user_consent_display_name  = "Access APIs"
      value                      = "api.access"
    }
  }

  required_resource_access {
    resource_app_id = "00000003-0000-0000-c000-000000000000" # Microsoft Graph

    resource_access {
      id   = "e1fe6dd8-ba31-4d61-89e7-88639da4683d" # User.Read
      type = "Scope"
    }
    resource_access {
      id   = "37f7f235-527c-4136-accd-4a02d197296e" # openid
      type = "Scope"
    }
    resource_access {
      id   = "14dad69e-099b-42c9-810b-d002981feec1" # profile
      type = "Scope"
    }
  }

  web {
    implicit_grant {
      access_token_issuance_enabled = false
      id_token_issuance_enabled     = false
    }
  }
}

# ─── Service Principal (Enterprise App) ──────────────────────
resource "azuread_service_principal" "main" {
  client_id                    = azuread_application.main.client_id
  app_role_assignment_required = false # Allow all tenant users to sign in
}

# ─── Assign "Admin" role to the deploying user ───────────────
resource "azuread_app_role_assignment" "deployer_admin" {
  app_role_id         = "00000000-0000-0000-0000-000000000010" # Admin
  principal_object_id = data.azurerm_client_config.current.object_id
  resource_object_id  = azuread_service_principal.main.object_id
}
