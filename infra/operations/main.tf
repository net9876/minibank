terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm" }
  }
}

variable "name_suffix" { type = string }
variable "resource_group" { type = string }
variable "location" { type = string }
variable "tags" { type = map(string) }
variable "tenant_id" { type = string }
variable "sql_server_id" { type = string }
variable "sql_host" { type = string }
variable "sql_database" { type = string }
variable "policy_blob_endpoint" { type = string }
variable "policy_container" { type = string }
variable "policy_scope" { type = string }
variable "insights_connection" {
  type      = string
  sensitive = true
}
variable "publisher_email" { type = string }
variable "api_app_client_id" { type = string }
variable "backend_app_client_id" { type = string }
variable "ops_group_id" { type = string }

locals {
  backend_audience = "api://${var.backend_app_client_id}"
  foundry_name     = "shared-lab-foundry"
}

data "azurerm_cognitive_account" "foundry" {
  name                = local.foundry_name
  resource_group_name = "common"
}

resource "azurerm_virtual_network" "functions" {
  name                = "vnet-minibank"
  resource_group_name = var.resource_group
  location            = var.location
  address_space       = ["10.184.32.0/24"]
  tags                = var.tags
}

resource "azurerm_subnet" "functions" {
  name                 = "Functions"
  resource_group_name  = var.resource_group
  virtual_network_name = azurerm_virtual_network.functions.name
  address_prefixes     = ["10.184.32.0/26"]
  service_endpoints    = ["Microsoft.Sql"]

  delegation {
    name = "FlexConsumption"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_mssql_virtual_network_rule" "functions" {
  name      = "FunctionsSubnet"
  server_id = var.sql_server_id
  subnet_id = azurerm_subnet.functions.id
}

resource "azurerm_user_assigned_identity" "functions" {
  name                = "id-minibank-functions"
  resource_group_name = var.resource_group
  location            = var.location
  tags                = var.tags
}

resource "azurerm_storage_account" "functions" {
  name                            = "mbfunc${var.name_suffix}"
  resource_group_name             = var.resource_group
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  tags                            = var.tags
}

resource "azurerm_storage_container" "deployment" {
  name                  = "function-releases"
  storage_account_id    = azurerm_storage_account.functions.id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "function_storage" {
  scope                            = azurerm_storage_account.functions.id
  role_definition_name             = "Storage Blob Data Owner"
  principal_id                     = azurerm_user_assigned_identity.functions.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "policy_read" {
  scope                            = var.policy_scope
  role_definition_name             = "Storage Blob Data Reader"
  principal_id                     = azurerm_user_assigned_identity.functions.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "model_invoke" {
  scope                            = data.azurerm_cognitive_account.foundry.id
  role_definition_name             = "Cognitive Services OpenAI User"
  principal_id                     = azurerm_user_assigned_identity.functions.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_api_management" "gateway" {
  name                = "minibank-api-${var.name_suffix}"
  resource_group_name = var.resource_group
  location            = var.location
  publisher_name      = "MiniBank Lab"
  publisher_email     = var.publisher_email
  sku_name            = "Consumption_0"
  tags                = var.tags

  identity { type = "SystemAssigned" }
}

resource "azurerm_service_plan" "functions" {
  name                = "plan-minibank-functions"
  resource_group_name = var.resource_group
  location            = var.location
  os_type             = "Linux"
  sku_name            = "FC1"
  tags                = var.tags
}

resource "azurerm_function_app_flex_consumption" "payments" {
  name                              = "minibank-functions-${var.name_suffix}"
  resource_group_name               = var.resource_group
  location                          = var.location
  service_plan_id                   = azurerm_service_plan.functions.id
  storage_container_type            = "blobContainer"
  storage_container_endpoint        = "${trimsuffix(azurerm_storage_account.functions.primary_blob_endpoint, "/")}/${azurerm_storage_container.deployment.name}"
  storage_authentication_type       = "UserAssignedIdentity"
  storage_user_assigned_identity_id = azurerm_user_assigned_identity.functions.id
  virtual_network_subnet_id         = azurerm_subnet.functions.id
  runtime_name                      = "python"
  runtime_version                   = "3.12"
  maximum_instance_count            = 40
  instance_memory_in_mb             = 2048
  https_only                        = true
  tags                              = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.functions.id]
  }

  site_config {
    application_insights_connection_string = var.insights_connection
    minimum_tls_version                    = "1.2"
  }

  auth_settings_v2 {
    auth_enabled           = true
    require_authentication = true
    unauthenticated_action = "Return401"
    active_directory_v2 {
      client_id            = var.backend_app_client_id
      tenant_auth_endpoint = "https://login.microsoftonline.com/${var.tenant_id}/v2.0"
      allowed_audiences    = [var.backend_app_client_id, local.backend_audience]
      allowed_identities   = [azurerm_api_management.gateway.identity[0].principal_id]
    }
    login {}
  }

  app_settings = {
    AzureWebJobsStorage__accountName = azurerm_storage_account.functions.name
    AzureWebJobsStorage__credential  = "managedidentity"
    AzureWebJobsStorage__clientId    = azurerm_user_assigned_identity.functions.client_id
    MINIBANK_IDENTITY_CLIENT_ID      = azurerm_user_assigned_identity.functions.client_id
    SQL_HOST                         = var.sql_host
    SQL_DATABASE                     = var.sql_database
    POLICY_BLOB_ENDPOINT             = var.policy_blob_endpoint
    POLICY_CONTAINER                 = var.policy_container
    FOUNDRY_OPENAI_URL               = "https://${local.foundry_name}.openai.azure.com/openai/v1/"
    FOUNDRY_MODEL_DEPLOYMENT         = "gpt-4.1-mini"
  }

  depends_on = [azurerm_role_assignment.function_storage, azurerm_mssql_virtual_network_rule.functions]
}

resource "azurerm_api_management_api" "payments" {
  name                  = "minibank-payments"
  resource_group_name   = var.resource_group
  api_management_name   = azurerm_api_management.gateway.name
  revision              = "1"
  display_name          = "MiniBank Payments"
  path                  = "minibank"
  protocols             = ["https"]
  subscription_required = false
  service_url           = "https://${azurerm_function_app_flex_consumption.payments.default_hostname}"

  import {
    content_format = "openapi+json"
    content_value  = file("${path.module}/openapi.json")
  }
}

resource "azurerm_api_management_api_policy" "payments" {
  api_name            = azurerm_api_management_api.payments.name
  api_management_name = azurerm_api_management.gateway.name
  resource_group_name = var.resource_group
  xml_content = templatefile("${path.module}/policy.xml.tftpl", {
    tenant           = var.tenant_id
    audience         = var.api_app_client_id
    group            = var.ops_group_id
    backend_audience = local.backend_audience
  })
}

output "deployment" {
  value = {
    gateway_url            = "${azurerm_api_management.gateway.gateway_url}/minibank"
    gateway_principal_id   = azurerm_api_management.gateway.identity[0].principal_id
    function_name          = azurerm_function_app_flex_consumption.payments.name
    function_identity_name = azurerm_user_assigned_identity.functions.name
    function_principal_id  = azurerm_user_assigned_identity.functions.principal_id
  }
}
