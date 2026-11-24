terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.66.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.7.0"
    }
  }
  backend "azurerm" {}
}

provider "azurerm" {
  features {}
  subscription_id                 = var.subscription_id
  resource_provider_registrations = "none"
  storage_use_azuread             = true
}

data "azurerm_client_config" "current" {}

variable "subscription_id" { type = string }
variable "location" { type = string }
variable "sql_location" {
  type        = string
  default     = "centralus"
  description = "Region for SQL and its consuming operations stack."
}
variable "sql_admin_name" { type = string }
variable "sql_admin_object_id" { type = string }
variable "deployment_principal_id" { type = string }
variable "enable_sql_database" {
  type        = bool
  default     = true
  description = "Whether MiniBankPayments exists. The SQL server and its firewall remain provisioned."
}
variable "sql_client_ipv4" {
  type        = string
  description = "IPv4 of the deployment workstation for the initial SQL load."
}

locals {
  suffix                 = substr(sha256(var.subscription_id), 0, 12)
  tags                   = { project = "minibank", environment = "lab" }
  payments_database_name = "MiniBankPayments"
  policy_container_scope = "${azurerm_storage_account.lab.id}/blobServices/default/containers/${azurerm_storage_container.policies.name}"
}

resource "azurerm_resource_group" "lab" {
  name     = "rg-minibank-lab"
  location = var.location
  tags     = local.tags
}

resource "azurerm_storage_account" "lab" {
  name                            = "mbdata${local.suffix}"
  resource_group_name             = azurerm_resource_group.lab.name
  location                        = azurerm_resource_group.lab.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  tags                            = local.tags

  blob_properties {
    versioning_enabled = true
  }
}

resource "azurerm_storage_container" "policies" {
  name                  = "policy-library"
  storage_account_id    = azurerm_storage_account.lab.id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "policy_publisher" {
  scope                = local.policy_container_scope
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.deployment_principal_id
}

resource "azurerm_mssql_server" "lab" {
  name                          = "minibank-sql-${local.suffix}-${var.sql_location}"
  resource_group_name           = azurerm_resource_group.lab.name
  location                      = var.sql_location
  version                       = "12.0"
  minimum_tls_version           = "1.2"
  public_network_access_enabled = true
  tags                          = local.tags

  azuread_administrator {
    login_username              = var.sql_admin_name
    object_id                   = var.sql_admin_object_id
    tenant_id                   = data.azurerm_client_config.current.tenant_id
    azuread_authentication_only = true
  }
}

resource "azurerm_mssql_firewall_rule" "deployment" {
  name             = "DeploymentWorkstation"
  server_id        = azurerm_mssql_server.lab.id
  start_ip_address = var.sql_client_ipv4
  end_ip_address   = var.sql_client_ipv4
}

resource "azurerm_mssql_database" "payments" {
  count                = var.enable_sql_database ? 1 : 0
  name                 = local.payments_database_name
  server_id            = azurerm_mssql_server.lab.id
  sku_name             = "Basic"
  storage_account_type = "Local"
  tags                 = local.tags
}

moved {
  from = azurerm_mssql_database.payments
  to   = azurerm_mssql_database.payments[0]
}

resource "azurerm_log_analytics_workspace" "lab" {
  name                = "log-minibank-${local.suffix}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_application_insights" "lab" {
  name                = "appi-minibank-${local.suffix}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  workspace_id        = azurerm_log_analytics_workspace.lab.id
  application_type    = "web"
  tags                = local.tags
}

output "resource_group" { value = azurerm_resource_group.lab.name }
output "sql_host" { value = azurerm_mssql_server.lab.fully_qualified_domain_name }
output "sql_database" { value = local.payments_database_name }
output "policy_storage" { value = azurerm_storage_account.lab.name }
output "policy_container" { value = azurerm_storage_container.policies.name }
