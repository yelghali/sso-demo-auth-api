# ─── Entra ID (Azure AD) App Registration ───────────────────────

resource "azuread_application" "main" {
  display_name = "${var.prefix}-spa"

  # Emit Entra security groups in JWT tokens
  group_membership_claims = ["SecurityGroup"]

  # SPA auth (MSAL.js) — redirect URIs use the App Gateway hostname
  single_page_application {
    redirect_uris = [
      "https://${local.hostname}/",
      "https://${local.hostname}/app1/",
      "https://${local.hostname}/app2/",
      "https://${local.hostname}/app3/",
    ]
  }

  # Include groups claim in ID token
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

# App password not needed for SPA (uses auth code + PKCE)
# Service principal created automatically by Entra when app is registered
