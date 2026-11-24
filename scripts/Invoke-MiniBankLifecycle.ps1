[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Status','PlanStart','Start','PlanStop','Stop','CaptureMcp')] [string] $Action,
    [ValidateSet('Sql','Mcp')] [string] $Component,
    [switch] $WritersStopped,
    [switch] $SeedNew
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$env:AZURE_LOGGING_ENABLE_LOG_FILE = 'false'
$env:AZURE_CORE_COLLECT_TELEMETRY = 'false'
if ($Action -ne 'Status' -and !$Component) { throw 'Select -Component Sql or Mcp.' }
if ($Action -eq 'CaptureMcp' -and $Component -ne 'Mcp') { throw 'CaptureMcp requires -Component Mcp.' }

$infra = Join-Path $PSScriptRoot '../infra'
$configPath = Join-Path $infra 'lab.auto.tfvars.json'
$backendPath = Join-Path $infra 'backend.local.hcl'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable
$subscription = ([guid]$config.subscription_id).ToString()
$group = 'rg-minibank-lab'
$sqlRegion = $config.sql_location ?? 'centralus'
$suffix = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($config.subscription_id))).Substring(0,12).ToLowerInvariant()
$sqlServer = "minibank-sql-$suffix-$sqlRegion"
$sqlHost = "$sqlServer.database.windows.net"
$sqlName = 'MiniBankPayments'
$consumption = "minibank-api-$suffix"
$mcpName = "minibank-mcp-$suffix"
$scope = "/subscriptions/$subscription/resourceGroups/$group/providers"
$sqlServerId = "$scope/Microsoft.Sql/servers/$sqlServer"
$sqlId = "$sqlServerId/databases/$sqlName"
$mcpId = "$scope/Microsoft.ApiManagement/service/$mcpName"
$paymentsMcpApi = "$mcpId/apis/payment-investigation"
$paymentsMcpUrl = "https://$mcpName.azure-api.net/payment-investigation/mcp"
$existingId = "$scope/Microsoft.ApiManagement/service/$consumption"

$root = Join-Path $env:LOCALAPPDATA "MiniBank-Lifecycle/$subscription"
$null = New-Item -ItemType Directory -Force -Path $root
$archive = Join-Path $root 'mcp.json'
$sqlJournal = Join-Path $root 'sql-backup.json'
$lockPath = Join-Path $root 'lifecycle.lock'

function Connect-Arm {
    $token = az account get-access-token --subscription $subscription --resource 'https://management.azure.com/' --query accessToken -o tsv --only-show-errors
    @{ Authentication = 'Bearer'; Token = ConvertTo-SecureString $token -AsPlainText -Force }
}

$arm = Connect-Arm

function Get-AzureResource($id, $version) {
    $result = Invoke-WebRequest @arm -Uri "https://management.azure.com$($id)?api-version=$version" -SkipHttpErrorCheck
    if ($result.StatusCode -eq 401) {
        $arm = Connect-Arm
        $result = Invoke-WebRequest @arm -Uri "https://management.azure.com$($id)?api-version=$version" -SkipHttpErrorCheck
    }
    if ($result.StatusCode -eq 404) { return }
    if ($result.StatusCode -ne 200) { throw "Read $id failed with HTTP $($result.StatusCode)." }
    $value = $result.Content | ConvertFrom-Json -AsHashtable -Depth 100
    if ($value.id -ine $id) { throw "ARM returned a different resource for $id." }
    $value
}

function Get-LiveSql { Get-AzureResource $sqlId '2023-08-01' }
function Get-LiveMcp { Get-AzureResource $mcpId '2024-05-01' }

function Assert-McpOwner($resource) {
    if ($resource -and ($resource.sku.name -ne 'Developer' -or $resource.sku.capacity -ne 1 -or
        $resource.tags.project -ne 'minibank' -or $resource.tags.lifecycle -ne 'mcp-disposable')) {
        throw "Gateway $mcpId does not have the expected Developer_1 SKU and lifecycle tags."
    }
}

function Write-JsonAtomic($path, $value) {
    $temporary = "$path.$([guid]::NewGuid()).tmp"
    [IO.File]::WriteAllText($temporary, ($value | ConvertTo-Json -Depth 30))
    [IO.File]::Move($temporary, $path, $true)
}

function Read-Json($path) {
    if (Test-Path -LiteralPath $path) { Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable }
}

function Invoke-SqlQuery($query) {
    $connection = [System.Data.SqlClient.SqlConnection]::new("Server=tcp:$sqlHost,1433;Initial Catalog=$sqlName;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;")
    try {
        $connection.AccessToken = az account get-access-token --resource 'https://database.windows.net/' --subscription $subscription --query accessToken -o tsv --only-show-errors
        $connection.Open()
        $command = $connection.CreateCommand()
        try {
            $command.CommandText = $query
            $command.CommandTimeout = 90
            $command.ExecuteScalar()
        } finally { $command.Dispose() }
    } finally { $connection.Dispose() }
}

function Get-SqlSummary {
    Invoke-SqlQuery @'
SELECT (SELECT
    (SELECT COUNT_BIG(*) FROM dbo.Customer) AS customers,
    (SELECT COUNT_BIG(*) FROM dbo.Account) AS accounts,
    (SELECT COUNT_BIG(*) FROM dbo.Beneficiary) AS beneficiaries,
    (SELECT COUNT_BIG(*) FROM dbo.Payment) AS payments,
    (SELECT COUNT_BIG(*) FROM dbo.PaymentEvent) AS events,
    (SELECT amount FROM dbo.Payment WHERE paymentId = 'PAY-1042') AS pay1042Amount,
    (SELECT reasonCode FROM dbo.Payment WHERE paymentId = 'PAY-1042') AS pay1042Reason
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
'@
}

function Find-SqlPackage {
    $tool = Get-Command SqlPackage -ErrorAction SilentlyContinue
    if ($tool) { return $tool.Source }
    $portable = Join-Path $env:LOCALAPPDATA 'MiniBank-Lifecycle/tools/sqlpackage/sqlpackage.exe'
    if (Test-Path -LiteralPath $portable) { return $portable }
}

function Use-SqlPackage($operation, $archivePath) {
    $tool = Find-SqlPackage
    if (!$tool) { throw 'Install Microsoft SqlPackage before stopping or restoring the SQL database. See docs/MiniBank-Lifecycle.md.' }
    $connection = "Data Source=tcp:$sqlHost,1433;Initial Catalog=$sqlName;Encrypt=True;TrustServerCertificate=False;Authentication=Active Directory Default;Connect Timeout=60;"
    if ($operation -eq 'Export') {
        & $tool /Action:Export "/SourceConnectionString:$connection" "/TargetFile:$archivePath" /p:VerifyExtraction=True
    } else {
        & $tool /Action:Import "/TargetConnectionString:$connection" "/SourceFile:$archivePath"
    }
}

function Assert-SqlArchive($journal) {
    if ($journal.id -ine $sqlId -or [IO.Path]::GetFileName($journal.archive) -ne $journal.archive) {
        throw 'SQL backup journal does not match the target database.'
    }
    $file = Join-Path $root $journal.archive
    if (!(Test-Path -LiteralPath $file) -or (Get-FileHash -LiteralPath $file).Hash -ne $journal.hash) {
        throw "The SQL backup at $file is missing or does not match the recorded hash."
    }
    $file
}

function Backup-Sql($live) {
    if (!$WritersStopped) { throw 'Pause SQL write jobs and sessions, then rerun Stop with -WritersStopped. The lab REST API is read-only.' }
    if ($live.sku.name -ne 'Basic' -or $live.properties.status -ne 'Online' -or !$live.properties.creationDate) {
        throw 'The expected Basic database must be Online before export.'
    }
    $summary = Get-SqlSummary
    $name = "sql-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))-$([guid]::NewGuid().ToString('N').Substring(0,8)).bacpac"
    $file = Join-Path $root $name
    Use-SqlPackage Export $file
    $zip = [IO.Compression.ZipFile]::OpenRead($file)
    try {
        if (!$zip.GetEntry('model.xml') -or !$zip.GetEntry('Origin.xml')) { throw 'The SQL export is missing its BACPAC manifest.' }
    } finally { $zip.Dispose() }
    if ((Get-SqlSummary) -cne $summary) { throw 'The database verification summary changed during export. Keep writers paused and retry.' }
    $backup = @{
        id=$sqlId; archive=$name; hash=(Get-FileHash -LiteralPath $file).Hash
        originalCreation=$live.properties.creationDate; phase='BackupReady'; summary=$summary
    }
    Write-JsonAtomic $sqlJournal $backup
    Write-Output "Verified BACPAC written to $file."
}

function Restore-Sql($live, $backup) {
    if (!$live -or $live.properties.status -ne 'Online') { throw 'SQL is not Online after Terraform start. Check Azure and retry.' }
    if ($backup -and $backup.phase -ne 'Restored' -and $live.properties.creationDate -ne $backup.originalCreation) {
        $file = Assert-SqlArchive $backup
        if ($backup.phase -ne 'ImportFinished') {
            $objects = Invoke-SqlQuery 'SELECT COUNT_BIG(*) FROM sys.objects WHERE is_ms_shipped = 0;'
            if ($objects -ne 0) { throw "SQL restore target is nonempty. Inspect the interrupted import and recover using $file before retrying. The current database was left in place." }
            Use-SqlPackage Import $file
            $backup.phase = 'ImportFinished'
            Write-JsonAtomic $sqlJournal $backup
        }
        if ((Get-SqlSummary) -cne $backup.summary) { throw "SQL restore check did not match the saved counts and PAY-1042 data in $file." }
        & (Join-Path $PSScriptRoot 'Deploy-PaymentsApi.ps1') -SubscriptionId $subscription -SqlAccessOnly
        $backup.phase = 'Restored'
        Write-JsonAtomic $sqlJournal $backup
    } elseif ($SeedNew) {
        if ($backup) { throw 'A SQL backup journal exists. Resume recovery before requesting a new seed.' }
        if ((Invoke-SqlQuery 'SELECT COUNT_BIG(*) FROM sys.objects WHERE is_ms_shipped = 0;') -ne 0) {
            throw 'SeedNew is only accepted for an empty SQL database.'
        }
        $results = & (Join-Path $PSScriptRoot 'Initialize-Data.ps1') -SubscriptionId $subscription -SqlOnly
        $results
        $first = Get-SqlSummary
        $null = & (Join-Path $PSScriptRoot 'Initialize-Data.ps1') -SubscriptionId $subscription -SqlOnly
        if ((Get-SqlSummary) -cne $first) { throw 'Repeat seed changed the SQL verification summary.' }
        & (Join-Path $PSScriptRoot 'Deploy-PaymentsApi.ps1') -SubscriptionId $subscription -SqlAccessOnly
    }
    Get-SqlSummary
}

function Get-PlanChanges($tfDirectory, $plan, [bool]$destroy) {
    $json = terraform "-chdir=$tfDirectory" show -json $plan | ConvertFrom-Json -AsHashtable -Depth 100
    $allowed = if ($Component -eq 'Sql') { @('azurerm_mssql_database.payments[0]') } else {
        @('azurerm_api_management.mcp','azurerm_api_management_policy.authenticate','azurerm_api_management_api.payments',
            'azapi_resource.payments_mcp','azapi_resource.mcp_tool["GetPayment"]','azapi_resource.mcp_tool["ExplainHold"]')
    }
    foreach ($entry in $json.resource_changes) {
        $change = $entry.change
        if ($entry.mode -ne 'managed' -or ($change.actions -join ',') -eq 'no-op') { continue }
        if ($entry.address -notin $allowed -or ($change.actions -join ',') -ne $(if ($destroy) {'delete'} else {'create'})) {
            throw "Plan is outside the requested scope: $($entry.address) [$($change.actions -join ',')]."
        }
        if ($Component -eq 'Sql') {
            $spec = if ($destroy) { $change.before } else { $change.after }
            if ($spec.server_id -ine $sqlServerId -or $spec.name -ne $sqlName -or
                ($destroy -and $spec.id -ine $sqlId) -or (!$destroy -and $spec.sku_name -ne 'Basic')) { throw 'Unexpected SQL database in plan.' }
        } else {
            if ($destroy -and $change.before.id -ine $mcpId -and $change.before.id -inotlike "$mcpId/*") { throw 'Unexpected APIM scope in destroy plan.' }
            if (!$destroy -and $entry.address -eq 'azurerm_api_management.mcp' -and
                ($change.after.name -ne $mcpName -or $change.after.resource_group_name -ne $group -or $change.after.sku_name -ne 'Developer_1')) {
                throw 'Unexpected Developer APIM in plan.'
            }
            if (!$destroy -and $entry.address -like 'azapi_resource.*' -and
                $change.after.name -notin @('payment-investigation','GetPayment','ExplainHold')) {
                throw 'Unexpected MCP server or tool in plan.'
            }
        }
        if ($destroy) { Write-Host "Delete: $($change.before.id)" } else { Write-Host "Create: $($entry.address)" }
        $entry
    }
}

function Get-McpPlanVariables($gateway) {
    if ($gateway.sku.name -ne 'Consumption') { throw 'The existing Payments gateway is not the expected Consumption SKU.' }
    $policyId = "$existingId/apis/minibank-payments/policies/policy"
    $response = Invoke-RestMethod @arm -Uri "https://management.azure.com$($policyId)?api-version=2024-05-01&format=rawxml"
    $xml = [xml]$response.properties.value
    $authPolicy = $xml.SelectSingleNode('/policies/inbound/validate-azure-ad-token')
    $tenant = [guid]$authPolicy.GetAttribute('tenant-id')
    $audience = [guid]$authPolicy.SelectSingleNode('audiences/audience').InnerText
    $opsGroup = [guid]$authPolicy.SelectSingleNode("required-claims/claim[@name='groups']/value").InnerText
    @{
        subscription_id=$subscription; resource_group=$group; location=$gateway.location
        gateway_name=$mcpName; publisher_email=$gateway.properties.publisherEmail
        payments_url="https://$consumption.azure-api.net/minibank"
        tenant_id=$tenant.ToString(); payments_audience=$audience.ToString(); ops_group_id=$opsGroup.ToString()
    }
}

$lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    $sql = if (!$Component -or $Component -eq 'Sql') { Get-LiveSql }
    $mcp = if (!$Component -or $Component -eq 'Mcp') { Get-LiveMcp }
    if ($Action -eq 'Status') {
        if (!$Component -or $Component -eq 'Sql') {
            $journal = Read-Json $sqlJournal
            [pscustomobject]@{ resourceId=$sqlId; status=($sql.properties.status ?? 'Absent'); sku=$sql.sku.name; backupPhase=$journal.phase; hourlyUsd=if ($sql) {[math]::Round(0.161 / 24, 6)} }
        }
        if (!$Component -or $Component -eq 'Mcp') {
            $server = if ($mcp) { Get-AzureResource $paymentsMcpApi '2025-09-01-preview' }
            [pscustomobject]@{ resourceId=$mcpId; status=($mcp.properties.provisioningState ?? 'Absent'); sku=$mcp.sku.name; mcpEndpoint=if ($server) {$paymentsMcpUrl}; archiveExists=(Test-Path -LiteralPath $archive); hourlyUsd=if ($mcp) {0.07} }
        }
        if (!$Component) {
            $existing = Get-AzureResource $existingId '2024-05-01'
            [pscustomobject]@{ resourceId=$existingId; status=$existing.properties.provisioningState; sku=$existing.sku.name; endpoint="https://$consumption.azure-api.net/minibank" }
        }
        Write-Host 'SQL absent: payment data and guidance are offline. Developer APIM absent: its MCP endpoint is offline. Retained storage and monitoring remain separately metered.'
        return
    }
    Assert-McpOwner $mcp
    if ($Action -eq 'CaptureMcp') {
        if ($mcp.properties.provisioningState -ne 'Succeeded') { throw 'Developer APIM is not ready.' }
        & (Join-Path $PSScriptRoot 'Save-MiniBankMcp.ps1') Capture $mcpId $archive
        return
    }
    $destroy = $Action -in @('PlanStop','Stop')
    $planning = $Action -in @('PlanStart','PlanStop')
    $direction = if ($destroy) {'stop'} else {'start'}
    $plan = Join-Path $root "$Component-$direction.tfplan"
    $receipt = "$plan.json"
    $tfDirectory = if ($Component -eq 'Sql') { $infra } else { Join-Path $infra 'mcp-gateway' }

    if ($planning) {
        if (Test-Path -LiteralPath $receipt) { Remove-Item -LiteralPath $receipt }
        $options = @('-input=false','-no-color','-lock-timeout=60s',"-out=$plan")
        if ($destroy -and $Component -eq 'Mcp') { $options += '-destroy' }
        $gateway = Get-AzureResource $existingId '2024-05-01'
        if (!$gateway -or $gateway.sku.name -ne 'Consumption') { throw 'The existing MiniBank Consumption gateway could not be verified.' }
        if ($Component -eq 'Sql') {
            terraform "-chdir=$infra" init -no-color -input=false "-backend-config=$backendPath"
            $enableSql = if ($destroy) {'false'} else {'true'}
            $options += @('-target=azurerm_mssql_database.payments', "-var=enable_sql_database=$enableSql",
                '-var=enable_operations=true', "-var=apim_publisher_email=$($gateway.properties.publisherEmail)")
        } else {
            $key = "minibank-mcp-$suffix.tfstate"
            terraform "-chdir=$tfDirectory" init -no-color -input=false "-backend-config=$backendPath" "-backend-config=key=$key"
            $varFile = Join-Path $root 'mcp.tfvars.json'
            Write-JsonAtomic $varFile (Get-McpPlanVariables $gateway)
            $options += "-var-file=$varFile"
        }
        if ((terraform "-chdir=$tfDirectory" workspace show).Trim() -ne 'default') {
            throw 'Select the default Terraform workspace for MiniBank before running a lifecycle plan.'
        }
        try {
            terraform "-chdir=$tfDirectory" plan @options | Out-Null
            $changes = @(Get-PlanChanges $tfDirectory $plan $destroy)
            $live = if ($Component -eq 'Sql') { $sql } else { $mcp }
            $resourceAddress = if ($Component -eq 'Sql') {'azurerm_mssql_database.payments[0]'} else {'azurerm_api_management.mcp'}
            $hasResourceChange = @($changes | Where-Object { $_.address -eq $resourceAddress }).Count -gt 0
            if ($live -and (($destroy -and !$hasResourceChange) -or (!$destroy -and $hasResourceChange))) {
                throw 'Azure contains a resource missing from the selected Terraform state. Resolve Terraform ownership before proceeding.'
            }
            if ($Component -eq 'Mcp' -and !$destroy -and $mcp -and
                @($changes | Where-Object address -eq 'azapi_resource.payments_mcp').Count -and
                (Get-AzureResource $paymentsMcpApi '2025-09-01-preview')) {
                throw "MCP server $paymentsMcpApi already exists. Import it into the Developer Terraform state before starting."
            }
            Write-JsonAtomic $receipt @{
                component=$Component; direction=$direction; hash=(Get-FileHash -LiteralPath $plan).Hash
                sqlCreation=$sql.properties.creationDate
            }
        } catch {
            if (Test-Path -LiteralPath $plan) { Remove-Item -LiteralPath $plan }
            throw
        }
        Write-Host "Verified $($changes.Count) managed resource change(s)."
        Write-Host "Checked saved plan: $plan"
        return
    }

    $approved = Read-Json $receipt
    if (!$approved -or $approved.component -ne $Component -or $approved.direction -ne $direction -or
        $approved.hash -ne (Get-FileHash -LiteralPath $plan).Hash) {
        throw "Run and review Plan$direction for $Component before applying."
    }
    $changes = @(Get-PlanChanges $tfDirectory $plan $destroy)
    $backup = if ($Component -eq 'Sql') { Read-Json $sqlJournal }
    if ($destroy -and $changes.Count) {
        if ($Component -eq 'Sql') {
            if (!$sql -or $sql.properties.creationDate -ne $approved.sqlCreation) {
                throw 'The SQL database was removed or recreated since planning. Run PlanStop again.'
            }
            Backup-Sql $sql
        } elseif ($mcp) {
            & (Join-Path $PSScriptRoot 'Save-MiniBankMcp.ps1') Capture $mcpId $archive
        }
    }
    if (!$destroy -and $Component -eq 'Sql') {
        if ($backup -and $backup.phase -ne 'Restored') {
            $null = Assert-SqlArchive $backup
            if (!$sql -and !(Find-SqlPackage)) { throw 'Install SqlPackage before recreating the SQL database.' }
        } elseif (!$sql -and !$backup -and !$SeedNew) {
            throw 'No backup exists. Use -SeedNew only when the missing database is known to be disposable and should be created from fixtures.'
        } elseif (!$sql -and $backup.phase -eq 'Restored') {
            throw 'SQL disappeared after the last verified restore. Use Azure point-in-time recovery or reconcile the backup journal before creating a new database.'
        }
    }
    if ($changes.Count) {
        $applyOptions = @('-input=false', '-no-color', '-lock-timeout=60s')
        # APIM tool writes share the parent server's ETag.
        if ($Component -eq 'Mcp') { $applyOptions += '-parallelism=1' }
        terraform "-chdir=$tfDirectory" apply @applyOptions $plan
        Remove-Item -LiteralPath $receipt
    }
    if ($destroy) {
        $remaining = if ($Component -eq 'Sql') { Get-LiveSql } else { Get-LiveMcp }
        if ($remaining) { throw 'Azure still reports the resource. Run Status and wait for deletion to complete.' }
        Write-Output "$Component is absent in Azure."
    } elseif ($Component -eq 'Sql') {
        Restore-Sql (Get-LiveSql) $backup
    } else {
        $ready = Get-LiveMcp
        Assert-McpOwner $ready
        if ($ready.properties.provisioningState -ne 'Succeeded') { throw 'Developer APIM is still provisioning. Check Status and rerun PlanStart.' }
        & (Join-Path $PSScriptRoot 'Save-MiniBankMcp.ps1') Restore $mcpId $archive
        $url = "https://$mcpName.azure-api.net/minibank/payments/PAY-1042"
        $response = Invoke-WebRequest -Uri $url -SkipHttpErrorCheck -TimeoutSec 45
        if ($response.StatusCode -ne 401) { throw "Developer gateway readiness probe expected 401 and got $($response.StatusCode). Check gateway and policies before using MCP." }
        Write-Output "Developer gateway ready: $url (anonymous HTTP 401)."
        & (Join-Path $PSScriptRoot 'Test-MiniBankMcp.ps1') -Endpoint $paymentsMcpUrl
    }
} finally {
    $lock.Dispose()
}
