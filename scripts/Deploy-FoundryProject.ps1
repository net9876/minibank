[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Plan', 'Apply')] [string] $Phase,
    [Parameter(Mandatory)] [guid] $SubscriptionId
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$env:AZURE_LOGGING_ENABLE_LOG_FILE = 'false'
$env:AZURE_CORE_COLLECT_TELEMETRY = 'false'
$backend = Join-Path $PSScriptRoot '..\infra\backend.local.hcl'
$foundry = Join-Path $PSScriptRoot '..\infra\foundry'

Push-Location $foundry
try {
    if ($Phase -eq 'Plan') {
        $account = az cognitiveservices account show -g common -n shared-lab-foundry `
            --subscription $SubscriptionId -o json --only-show-errors | ConvertFrom-Json
        if ($account.kind -ne 'AIServices' -or !$account.properties.allowProjectManagement) {
            throw 'Existing account does not support Foundry projects.'
        }
        $modelState = az cognitiveservices account deployment show -g common -n shared-lab-foundry `
            --deployment-name 'gpt-4.1-mini' --subscription $SubscriptionId `
            --query properties.provisioningState -o tsv --only-show-errors
        if ($modelState -ne 'Succeeded') { throw "gpt-4.1-mini provisioning state is $modelState." }
        terraform init '-input=false' "-backend-config=$backend" '-backend-config=key=minibank/foundry.tfstate' -no-color
        terraform validate -no-color
        terraform plan '-input=false' '-out=foundry.tfplan' -var "subscription_id=$SubscriptionId" `
            -var "account_location=$($account.location)" -no-color
    } else {
        terraform apply '-input=false' -no-color foundry.tfplan
        $project = az rest --method get --url "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/common/providers/Microsoft.CognitiveServices/accounts/shared-lab-foundry/projects/proj-minibank?api-version=2025-06-01" `
            --query '{name:name,state:properties.provisioningState}' -o json --only-show-errors | ConvertFrom-Json
        if ($project.state -ne 'Succeeded') { throw "Foundry project provisioning state is $($project.state)." }
        $project | ConvertTo-Json -Compress
    }
} finally {
    Pop-Location
}
