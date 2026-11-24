terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.8.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.66.0"
    }
  }
  backend "azurerm" {}
}

provider "azapi" {
  subscription_id = var.subscription_id
}

provider "azurerm" {
  features {
    api_management {
      purge_soft_delete_on_destroy = true
      recover_soft_deleted         = false
    }
  }
  subscription_id                 = var.subscription_id
  resource_provider_registrations = "none"
}

variable "subscription_id" { type = string }
variable "resource_group" { type = string }
variable "location" { type = string }
variable "gateway_name" { type = string }
variable "publisher_email" { type = string }
variable "payments_url" { type = string }
variable "tenant_id" { type = string }
variable "payments_audience" { type = string }
variable "ops_group_id" { type = string }

resource "azurerm_api_management" "mcp" {
  name                = var.gateway_name
  location            = var.location
  resource_group_name = var.resource_group
  publisher_name      = "MiniBank Lab"
  publisher_email     = var.publisher_email
  sku_name            = "Developer_1"
  tags                = { project = "minibank", lifecycle = "mcp-disposable" }
}

resource "azurerm_api_management_policy" "authenticate" {
  api_management_id = azurerm_api_management.mcp.id
  xml_content = templatefile("${path.module}/authenticate.xml.tftpl", {
    tenant_id = var.tenant_id
    audience  = var.payments_audience
    group_id  = var.ops_group_id
  })
}

resource "azurerm_api_management_api" "payments" {
  name                  = "minibank-payments"
  resource_group_name   = var.resource_group
  api_management_name   = azurerm_api_management.mcp.name
  revision              = "1"
  display_name          = "MiniBank Payments"
  path                  = "minibank"
  protocols             = ["https"]
  service_url           = var.payments_url
  subscription_required = false

  import {
    content_format = "openapi+json"
    content_value  = file("${path.module}/../operations/openapi.json")
  }

  depends_on = [azurerm_api_management_policy.authenticate]
}

locals {
  mcp_api_version = "2025-09-01-preview"
  mcp_tools = {
    GetPayment = {
      path        = "/payments/{paymentId}"
      description = "Read a payment and its history by payment ID."
    }
    ExplainHold = {
      path        = "/payments/{paymentId}/guidance"
      description = "Read the hold recommendation and cited policy section for a payment."
    }
  }
}

data "azapi_resource_list" "payment_operations" {
  type      = "Microsoft.ApiManagement/service/apis/operations@2024-05-01"
  parent_id = trimsuffix(azurerm_api_management_api.payments.id, ";rev=1")

  response_export_values = ["value"]
}

locals {
  tool_operation_ids = {
    for name, tool in local.mcp_tools : name => [
      for operation in data.azapi_resource_list.payment_operations.output.value : operation.id
      if operation.properties.method == "GET" && operation.properties.urlTemplate == tool.path
    ]
  }
}

resource "azapi_resource" "payments_mcp" {
  type      = "Microsoft.ApiManagement/service/apis@${local.mcp_api_version}"
  parent_id = azurerm_api_management.mcp.id
  name      = "payment-investigation"

  # This ARM preview version is newer than the pinned provider's embedded schema.
  schema_validation_enabled = false

  body = {
    properties = {
      type                 = "mcp"
      displayName          = "MiniBank Payments MCP"
      description          = "MiniBank payment lookup and hold guidance."
      path                 = "payment-investigation"
      protocols            = ["https"]
      subscriptionRequired = false
    }
  }

  depends_on = [azurerm_api_management_api.payments]
}

resource "azapi_resource" "mcp_tool" {
  for_each  = local.mcp_tools
  type      = "Microsoft.ApiManagement/service/apis/tools@${local.mcp_api_version}"
  parent_id = azapi_resource.payments_mcp.id
  name      = each.key

  schema_validation_enabled = false

  body = {
    properties = {
      displayName = each.key
      description = each.value.description
      operationId = one(local.tool_operation_ids[each.key])
    }
  }

  lifecycle {
    precondition {
      condition     = length(local.tool_operation_ids[each.key]) == 1
      error_message = "Expected exactly one GET operation for ${each.value.path} on the Developer Payments API."
    }
  }
}

output "mcp_endpoint" {
  value = "${trimsuffix(azurerm_api_management.mcp.gateway_url, "/")}/${azapi_resource.payments_mcp.name}/mcp"
}
