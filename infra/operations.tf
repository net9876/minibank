variable "enable_operations" {
  type    = bool
  default = false
}

variable "apim_publisher_email" {
  type    = string
  default = ""
}

variable "ops_group_id" {
  type    = string
  default = null
}

variable "connector_redirect_uris" {
  type        = list(string)
  default     = []
  description = "OAuth redirect URIs supplied by the MiniBank Power Platform custom connector."
}

provider "azuread" {
  tenant_id = data.azurerm_client_config.current.tenant_id
}

locals {
  payments_scope_id = uuidv5("url", "minibank/${local.suffix}/Payments.Read")
  invoke_role_id    = uuidv5("url", "minibank/${local.suffix}/Payments.Invoke")
}

resource "azuread_group" "ops" {
  count            = var.enable_operations && var.ops_group_id == null ? 1 : 0
  display_name     = "MiniBankOps"
  security_enabled = true
  owners           = [var.deployment_principal_id]
  members          = [var.deployment_principal_id]
}

resource "azuread_application" "payments" {
  count                   = var.enable_operations ? 1 : 0
  display_name            = "MiniBank Payments API ${local.suffix}"
  sign_in_audience        = "AzureADMyOrg"
  group_membership_claims = ["SecurityGroup"]
  owners                  = [var.deployment_principal_id]

  api {
    requested_access_token_version = 2
    oauth2_permission_scope {
      id                         = local.payments_scope_id
      value                      = "Payments.Read"
      type                       = "User"
      admin_consent_display_name = "Read MiniBank payment details"
      admin_consent_description  = "Read synthetic payments and guidance as the signed-in operator."
      user_consent_display_name  = "Read MiniBank payments"
      user_consent_description   = "Read synthetic payments and guidance on your behalf."
      enabled                    = true
    }
  }
}

resource "azuread_application_identifier_uri" "payments" {
  count          = var.enable_operations ? 1 : 0
  application_id = azuread_application.payments[0].id
  identifier_uri = "api://${azuread_application.payments[0].client_id}"
}

resource "azuread_service_principal" "payments" {
  count     = var.enable_operations ? 1 : 0
  client_id = azuread_application.payments[0].client_id
}

resource "azuread_application" "connector" {
  count            = var.enable_operations ? 1 : 0
  display_name     = "MiniBank Power Platform Connector ${local.suffix}"
  sign_in_audience = "AzureADMyOrg"
  owners           = [var.deployment_principal_id]

  required_resource_access {
    resource_app_id = azuread_application.payments[0].client_id
    resource_access {
      id   = local.payments_scope_id
      type = "Scope"
    }
  }

  web { redirect_uris = var.connector_redirect_uris }
}

resource "azuread_application" "backend" {
  count            = var.enable_operations ? 1 : 0
  display_name     = "MiniBank Functions Backend ${local.suffix}"
  sign_in_audience = "AzureADMyOrg"
  owners           = [var.deployment_principal_id]

  api { requested_access_token_version = 2 }

  app_role {
    id                   = local.invoke_role_id
    value                = "Payments.Invoke"
    allowed_member_types = ["Application"]
    description          = "Allows API Management to invoke the MiniBank Functions backend."
    display_name         = "Invoke MiniBank backend"
    enabled              = true
  }
}

resource "azuread_application_identifier_uri" "backend" {
  count          = var.enable_operations ? 1 : 0
  application_id = azuread_application.backend[0].id
  identifier_uri = "api://${azuread_application.backend[0].client_id}"
}

resource "azuread_service_principal" "backend" {
  count                        = var.enable_operations ? 1 : 0
  client_id                    = azuread_application.backend[0].client_id
  app_role_assignment_required = true
}

resource "azuread_app_role_assignment" "gateway" {
  count               = var.enable_operations ? 1 : 0
  app_role_id         = local.invoke_role_id
  principal_object_id = module.operations[0].deployment.gateway_principal_id
  resource_object_id  = azuread_service_principal.backend[0].object_id
}

module "operations" {
  count  = var.enable_operations ? 1 : 0
  source = "./operations"

  name_suffix           = local.suffix
  resource_group        = azurerm_resource_group.lab.name
  location              = var.sql_location
  tags                  = local.tags
  tenant_id             = data.azurerm_client_config.current.tenant_id
  sql_server_id         = azurerm_mssql_server.lab.id
  sql_host              = azurerm_mssql_server.lab.fully_qualified_domain_name
  sql_database          = local.payments_database_name
  policy_blob_endpoint  = trimsuffix(azurerm_storage_account.lab.primary_blob_endpoint, "/")
  policy_container      = azurerm_storage_container.policies.name
  policy_scope          = local.policy_container_scope
  insights_connection   = azurerm_application_insights.lab.connection_string
  publisher_email       = var.apim_publisher_email
  api_app_client_id     = azuread_application.payments[0].client_id
  backend_app_client_id = azuread_application.backend[0].client_id
  ops_group_id          = var.ops_group_id != null ? var.ops_group_id : azuread_group.ops[0].object_id
}

output "operations" {
  value = var.enable_operations ? merge(module.operations[0].deployment, {
    api_app_client_id   = azuread_application.payments[0].client_id
    connector_client_id = azuread_application.connector[0].client_id
    payments_scope_id   = local.payments_scope_id
    tenant_id           = data.azurerm_client_config.current.tenant_id
  }) : null
}
