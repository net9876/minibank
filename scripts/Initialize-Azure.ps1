[CmdletBinding()]
param(
    [Parameter(Mandatory)] [guid] $SubscriptionId,
    [Parameter(Mandatory)] [ipaddress] $SqlClientIpv4,
    [string] $Location = 'eastus',
    [string] $StateStorageAccount
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$env:AZURE_LOGGING_ENABLE_LOG_FILE = 'false'
$env:AZURE_CORE_COLLECT_TELEMETRY = 'false'

if ($SqlClientIpv4.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
    throw 'Supply an IPv4 address for the initial SQL load.'
}
$infra = Join-Path $PSScriptRoot '..\infra'
$sub = $SubscriptionId.ToString()
$account = az account show --subscription $sub -o json --only-show-errors | ConvertFrom-Json
if ($account.state -ne 'Enabled') { throw 'The selected subscription is not enabled.' }
$operator = az ad signed-in-user show --query '{id:id,upn:userPrincipalName}' -o json --only-show-errors | ConvertFrom-Json
if (!$operator.id -or !$operator.upn) { throw 'Sign in to the selected tenant as the lab deployment operator.' }
$common = az group show --name common --subscription $sub -o json --only-show-errors | ConvertFrom-Json
$accounts = @(az storage account list --resource-group common --subscription $sub -o json --only-show-errors | ConvertFrom-Json)
if ($StateStorageAccount) {
    $state = $accounts | Where-Object name -eq $StateStorageAccount
    if (!$state) { throw 'The specified Terraform state account was not found in common.' }
} else {
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($sub))).ToLowerInvariant()
    $StateStorageAccount = "mbtfstate$($hash.Substring(0, 12))"
    $state = $accounts | Where-Object name -eq $StateStorageAccount
    if (!$state) {
        $state = az storage account create --resource-group common --subscription $sub `
            --name $StateStorageAccount --location $common.location --sku Standard_LRS --kind StorageV2 `
            --https-only true --min-tls-version TLS1_2 --allow-blob-public-access false `
            --allow-shared-key-access false --tags project=minibank purpose=terraform-state `
            -o json --only-show-errors | ConvertFrom-Json
        az storage account blob-service-properties update --account-name $StateStorageAccount `
            --resource-group common --subscription $sub --enable-versioning true `
            --enable-delete-retention true --delete-retention-days 14 --output none --only-show-errors
    }
}

$container = 'minibank-tfstate'
# ARM creates the private container without account keys or a storage data-plane token.
$containerUri = "https://management.azure.com$($state.id)/blobServices/default/containers/${container}?api-version=2023-05-01"
$requestPath = [IO.Path]::GetTempFileName()
try {
    Set-Content -LiteralPath $requestPath -Value '{"properties":{"publicAccess":"None"}}' -Encoding utf8
    az rest --method put --url $containerUri --body "@$requestPath" --output none --only-show-errors
} finally {
    Remove-Item -LiteralPath $requestPath -ErrorAction SilentlyContinue
}
$scope = "$($state.id)/blobServices/default/containers/$container"
$grants = @(az role assignment list --scope $scope --assignee $operator.id --include-inherited `
    --subscription $sub --query "[?roleDefinitionName=='Storage Blob Data Contributor' || roleDefinitionName=='Storage Blob Data Owner'].id" `
    -o json --only-show-errors | ConvertFrom-Json)
if (!$grants.Count) {
    az role assignment create --scope $scope --assignee-object-id $operator.id --assignee-principal-type User `
        --role 'Storage Blob Data Contributor' --subscription $sub --output none --only-show-errors
}

@"
resource_group_name  = "common"
storage_account_name = "$StateStorageAccount"
container_name       = "$container"
key                  = "minibank/lab.tfstate"
subscription_id      = "$sub"
tenant_id            = "$($account.tenantId)"
use_azuread_auth     = true
use_cli              = true
"@ | Set-Content -LiteralPath (Join-Path $infra 'backend.local.hcl') -Encoding utf8

@{
    subscription_id = $sub
    location = $Location
    sql_client_ipv4 = $SqlClientIpv4.ToString()
    sql_admin_object_id = $operator.id
    sql_admin_name = $operator.upn
    deployment_principal_id = $operator.id
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $infra 'lab.auto.tfvars.json') -Encoding utf8
Write-Output "Terraform backend $StateStorageAccount/$container/minibank/lab.tfstate configured."
