[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Plan', 'Apply')] [string] $Phase,
    [switch] $EnableOperations,
    [System.Net.Mail.MailAddress] $PublisherEmail,
    [guid] $OpsGroupId = [guid]::Empty
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$env:AZURE_LOGGING_ENABLE_LOG_FILE = 'false'
$env:AZURE_CORE_COLLECT_TELEMETRY = 'false'

Push-Location (Join-Path $PSScriptRoot '..\infra')
try {
    if ($Phase -eq 'Plan') {
        terraform init '-input=false' '-backend-config=backend.local.hcl' -no-color
        $planArgs = @('-input=false', '-out=lab.tfplan')
        if ($EnableOperations) {
            if (!$PublisherEmail) { throw 'Provide a valid APIM publisher email when enabling operations.' }
            $planArgs += @('-var', 'enable_operations=true', '-var', "apim_publisher_email=$($PublisherEmail.Address)")
            if ($OpsGroupId -ne [guid]::Empty) { $planArgs += @('-var', "ops_group_id=$OpsGroupId") }
        } elseif (Test-Path -LiteralPath 'operations.tf') {
            $existing = terraform output -json
            if (($existing | ConvertFrom-Json).operations.value) {
                throw 'The existing lab has operations enabled. Supply -EnableOperations to continue.'
            }
        }
        terraform validate -no-color
        terraform plan -no-color @planArgs
    } else {
        if ($EnableOperations -or $PublisherEmail -or $OpsGroupId -ne [guid]::Empty) {
            throw 'Supply operation settings when planning, then apply the saved plan.'
        }
        terraform apply '-input=false' -no-color lab.tfplan
    }
} finally {
    Pop-Location
}
