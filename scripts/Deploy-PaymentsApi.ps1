[CmdletBinding()]
param(
    [Parameter(Mandatory)] [guid] $SubscriptionId,
    [switch] $SqlAccessOnly
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$env:AZURE_LOGGING_ENABLE_LOG_FILE = 'false'
$env:AZURE_CORE_COLLECT_TELEMETRY = 'false'

$infra = Join-Path $PSScriptRoot '..\infra'
$source = Join-Path $PSScriptRoot '..\api'
$outputs = terraform "-chdir=$infra" output -json | ConvertFrom-Json
$operations = $outputs.operations.value
if (!$operations) { throw 'Apply the Terraform plan with enable_operations=true first.' }
$group = $outputs.resource_group.value
$server = $outputs.sql_host.value
$database = $outputs.sql_database.value
$identity = az identity show --resource-group $group --name $operations.function_identity_name `
    --subscription $SubscriptionId --query '{clientId:clientId,principalId:principalId}' -o json --only-show-errors |
    ConvertFrom-Json
if (!$identity.clientId -or $identity.principalId -ne $operations.function_principal_id) {
    throw 'The live Functions identity does not match the Terraform outputs.'
}
# Azure SQL uses the application client ID as the SID for a contained managed identity user.
$identitySid = [Convert]::ToHexString(([guid] $identity.clientId).ToByteArray())
$previousSid = [Convert]::ToHexString(([guid] $identity.principalId).ToByteArray())

if (!$SqlAccessOnly) {
    $appSettings = @(az functionapp config appsettings list --resource-group $group --name $operations.function_name `
        --subscription $SubscriptionId --query '[].name' -o tsv --only-show-errors)
    foreach ($setting in @('AzureWebJobsStorage__accountName', 'AzureWebJobsStorage__credential', 'AzureWebJobsStorage__clientId')) {
        if ($appSettings -notcontains $setting) { throw "Missing Functions host identity setting $setting." }
    }
    # AzureRM can regenerate legacy key-based storage settings on a Flex app configured for managed identity.
    $legacySettings = @($appSettings | Where-Object { $_ -in @('AzureWebJobsStorage', 'DEPLOYMENT_STORAGE_CONNECTION_STRING') })
    if ($legacySettings) {
        az functionapp config appsettings delete --resource-group $group --name $operations.function_name `
            --subscription $SubscriptionId --setting-names @legacySettings --only-show-errors -o none
    }
}

$connection = [System.Data.SqlClient.SqlConnection]::new(
    "Server=tcp:$server,1433;Initial Catalog=$database;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;")
try {
    $connection.AccessToken = az account get-access-token --subscription $SubscriptionId `
        --resource 'https://database.windows.net/' --query accessToken -o tsv --only-show-errors
    $connection.Open()
    $command = $connection.CreateCommand()
    try {
        $command.CommandText = @"
SET XACT_ABORT ON;
BEGIN TRANSACTION;

IF EXISTS (
    SELECT 1 FROM sys.database_principals
    WHERE name = N'id-minibank-functions-client' AND (sid <> 0x$identitySid OR type <> 'E')
)
    THROW 50010, 'The SQL identity name already belongs to a different principal.', 1;

IF DATABASE_PRINCIPAL_ID(N'id-minibank-functions-client') IS NULL
    CREATE USER [id-minibank-functions-client] WITH SID = 0x$identitySid, TYPE = E;
EXEC(N'GRANT SELECT ON OBJECT::dbo.PaymentFacts TO [id-minibank-functions-client];
    GRANT SELECT ON OBJECT::dbo.PaymentHistory TO [id-minibank-functions-client];');

IF EXISTS (
    SELECT 1 FROM sys.database_principals
    WHERE name = N'id-minibank-functions' AND sid = 0x$previousSid AND type = 'E'
)
    EXEC(N'REVOKE CONNECT FROM [id-minibank-functions];
        REVOKE SELECT ON OBJECT::dbo.PaymentFacts FROM [id-minibank-functions];
        REVOKE SELECT ON OBJECT::dbo.PaymentHistory FROM [id-minibank-functions];');
COMMIT TRANSACTION;
"@
        $null = $command.ExecuteNonQuery()
    } finally {
        $command.Dispose()
    }
} finally {
    $connection.Dispose()
}
if ($SqlAccessOnly) {
    Write-Output 'Verified managed identity mapping and granted SELECT on PaymentFacts and PaymentHistory.'
    return
}

$zipPath = Join-Path ([IO.Path]::GetTempPath()) "minibank-api-$([guid]::NewGuid()).zip"
try {
    $releaseFiles = @('function_app.py', 'policy.py', 'host.json', 'requirements.txt') |
        ForEach-Object { Join-Path $source $_ }
    Compress-Archive -LiteralPath $releaseFiles -DestinationPath $zipPath
    $nativeErrors = $PSNativeCommandUseErrorActionPreference
    try {
        $PSNativeCommandUseErrorActionPreference = $false
        $deployment = az functionapp deployment source config-zip --resource-group $group --name $operations.function_name `
            --subscription $SubscriptionId --src $zipPath --build-remote true --timeout 900 --only-show-errors 2>&1
        $deploymentExit = $LASTEXITCODE
    } finally {
        $PSNativeCommandUseErrorActionPreference = $nativeErrors
    }
    $deploymentMessage = $deployment -join "`n"
    if ($deploymentExit -ne 0) {
        if ($deploymentMessage -notmatch 'Failed to fetch host key to check for function app status|Deployment was successful but the app appears to be unhealthy') {
            throw $deploymentMessage
        }
        Write-Output 'Azure CLI reported a host health-check error. Checking deployed function registrations through ARM.'
    } else {
        $deploymentMessage
    }
} finally {
    Remove-Item -LiteralPath $zipPath -ErrorAction SilentlyContinue
}

$deadline = [datetime]::UtcNow.AddMinutes(2)
do {
    $functionNames = @(az functionapp function list --resource-group $group --name $operations.function_name `
        --subscription $SubscriptionId --query '[].name' -o tsv --only-show-errors | ForEach-Object { ($_ -split '/')[-1] })
    if ($functionNames -contains 'GetPayment' -and $functionNames -contains 'ExplainHold') { break }
    Start-Sleep -Seconds 5
} while ([datetime]::UtcNow -lt $deadline)
if ($functionNames -notcontains 'GetPayment' -or $functionNames -notcontains 'ExplainHold') {
    throw 'The Functions runtime has not registered both payment operations.'
}
Write-Output 'Functions indexed GetPayment and ExplainHold.'

$response = Invoke-WebRequest -Uri "$($operations.gateway_url)/payments/PAY-1042" -SkipHttpErrorCheck -TimeoutSec 30
if ([int] $response.StatusCode -ne 401) { throw "APIM anonymous smoke test returned $($response.StatusCode)." }
Write-Output "APIM anonymous smoke test -> HTTP 401"
