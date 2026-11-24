terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = ">= 2.5, < 3.0"
    }
  }
  backend "azurerm" {}
}

variable "subscription_id" { type = string }
variable "account_location" { type = string }

provider "azapi" {
  subscription_id = var.subscription_id
}

locals {
  account_id = "/subscriptions/${var.subscription_id}/resourceGroups/common/providers/Microsoft.CognitiveServices/accounts/shared-lab-foundry"
}

resource "azapi_resource" "minibank" {
  type      = "Microsoft.CognitiveServices/accounts/projects@2025-06-01"
  name      = "proj-minibank"
  parent_id = local.account_id
  location  = var.account_location

  identity {
    type = "SystemAssigned"
  }

  body = {
    properties = {
      displayName = "MiniBank Lab"
      description = "Policy-grounded payment operations guidance for the synthetic MiniBank lab."
    }
  }

  response_export_values = ["properties.provisioningState", "properties.endpoints"]
}

output "project_id" { value = azapi_resource.minibank.id }
output "project_state" { value = azapi_resource.minibank.output.properties.provisioningState }
