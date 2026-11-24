[CmdletBinding()]
param(
    [Parameter(Mandatory)] [guid] $SubscriptionId,
    [switch] $SqlOnly
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$env:AZURE_LOGGING_ENABLE_LOG_FILE = 'false'
$env:AZURE_CORE_COLLECT_TELEMETRY = 'false'

$infra = Join-Path $PSScriptRoot '..\infra'
$data = Join-Path $PSScriptRoot '..\data'
$outputs = terraform "-chdir=$infra" output -json | ConvertFrom-Json
$group = $outputs.resource_group.value
$server = $outputs.sql_host.value
$database = $outputs.sql_database.value
$storage = $outputs.policy_storage.value
$container = $outputs.policy_container.value
$serverName = $server.Split('.')[0]
$sqlState = az sql db show -g $group -s $serverName -n $database --subscription $SubscriptionId `
    --query status -o tsv --only-show-errors
if ($sqlState -ne 'Online') { throw "SQL database is $sqlState." }
if (!$SqlOnly) {
    $null = az storage container show --name $container --account-name $storage `
        --subscription $SubscriptionId --auth-mode login --only-show-errors -o json
}

$snapshotPath = [IO.Path]::GetTempFileName()
try {
    python (Join-Path $data 'seed.py') --output $snapshotPath
    $snapshot = Get-Content -Raw -LiteralPath $snapshotPath
    $token = az account get-access-token --resource 'https://database.windows.net/' `
        --subscription $SubscriptionId --query accessToken -o tsv --only-show-errors
    $connection = [System.Data.SqlClient.SqlConnection]::new(
        "Server=tcp:$server,1433;Initial Catalog=$database;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;")
    try {
        $connection.AccessToken = $token
        $connection.Open()
        $command = $connection.CreateCommand()
        try {
            $command.CommandTimeout = 120
            $command.CommandText = Get-Content -Raw -LiteralPath (Join-Path $data 'schema.sql')
            $null = $command.ExecuteNonQuery()
            $command.CommandText = Get-Content -Raw -LiteralPath (Join-Path $data 'load.sql')
            $command.Parameters.Add('@snapshot', [Data.SqlDbType]::NVarChar, -1).Value = $snapshot
            $reader = $command.ExecuteReader()
            try {
                if (!$reader.Read()) { throw 'No SQL verification counts returned.' }
                $counts = [ordered]@{}
                for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                    $counts[$reader.GetName($i)] = $reader.GetInt64($i)
                }
                $counts | ConvertTo-Json -Compress
                if (!$reader.NextResult() -or !$reader.Read() -or $reader.IsDBNull(0) -or
                    $reader.GetInt64(0) -ne 186 -or $reader.GetDecimal(1) -ne [decimal] 1915309.98) {
                    throw 'The 2026-11-19 UTC daily hold metric did not match the seed fixture.'
                }
                Write-Output '2026-11-19 UTC: 186 held payments, 1915309.9800 USD.'
            } finally {
                $reader.Dispose()
            }
        } finally {
            $command.Dispose()
        }
    } finally {
        $connection.Dispose()
    }
} finally {
    Remove-Item -LiteralPath $snapshotPath -ErrorAction SilentlyContinue
}

if (!$SqlOnly) {
    & (Join-Path $PSScriptRoot 'Publish-Policies.ps1') -SubscriptionId $SubscriptionId -StorageAccount $storage -Container $container
}
