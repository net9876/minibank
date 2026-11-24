param(
    [Parameter(Mandatory)] [ValidateSet('Capture', 'Restore')] [string] $Action,
    [Parameter(Mandatory)] [string] $ServiceId,
    [Parameter(Mandatory)] [string] $Archive
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$version = '2025-09-01-preview'
$base = "https://management.azure.com$ServiceId"
$token = az account get-access-token --subscription ($ServiceId.Split('/')[2]) --resource 'https://management.azure.com/' --query accessToken -o tsv --only-show-errors
$auth = @{ Authentication = 'Bearer'; Token = ConvertTo-SecureString $token -AsPlainText -Force }

function Read-Arm($url, [switch] $Optional) {
    $response = Invoke-WebRequest @auth -Uri $url -SkipHttpErrorCheck
    if ($response.StatusCode -eq 404 -and $Optional) { return }
    if ($response.StatusCode -ne 200) { throw "GET $url returned HTTP $($response.StatusCode): $($response.Content)" }
    $response.Content | ConvertFrom-Json -AsHashtable -Depth 100
}

function Read-Collection($url) {
    do {
        $uri = [uri]$url
        if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'management.azure.com') { throw 'Unexpected ARM continuation URL.' }
        $page = Read-Arm $url
        $page.value
        $url = $page.nextLink
    } while ($url)
}

function Set-Arm($url, $properties) {
    $body = @{ properties = $properties } | ConvertTo-Json -Depth 100 -Compress
    $response = Invoke-WebRequest @auth -Uri $url -Method Put -ContentType 'application/json' -Headers @{'If-Match'='*'} -Body $body
    $location = @($response.Headers['Azure-AsyncOperation'])[0]
    if (!$location -and $response.StatusCode -eq 202) { $location = @($response.Headers.Location)[0] }
    if ($response.StatusCode -eq 202 -and !$location) { throw "ARM returned no status URL for $url." }
    if (!$location) { return }
    $uri = [uri]$location
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'management.azure.com') { throw 'Unexpected ARM status URL.' }
    for ($attempt = 0; $attempt -lt 36; $attempt++) {
        Start-Sleep -Seconds 5
        $operation = Read-Arm $location
        $status = $operation.status ?? $operation.properties.provisioningState
        if ($status -eq 'Succeeded') { return }
        if ($status -in @('Failed','Canceled')) { throw "ARM update for $url ended in $status." }
    }
    throw "ARM update for $url timed out. Check Status and retry PlanStart."
}

function Select-Properties($record, $names) {
    $result = [ordered]@{}
    foreach ($name in $names) {
        if ($null -ne $record[$name]) { $result[$name] = $record[$name] }
    }
    return $result
}

$apis = @(Read-Collection "$base/apis?api-version=$version")
$managedName = 'payment-investigation'
$managed = $apis | Where-Object { $_.name -eq $managedName }
$servers = @($apis | Where-Object { $_.properties.type -eq 'mcp' -and $_.name -ne $managedName })
if ($Action -eq 'Capture') {
    if ($managed) {
        if ($managed.properties.type -ne 'mcp') { throw "The Terraform MCP name $managedName is occupied by another API." }
        $customTools = @(Read-Collection "$base/apis/$managedName/tools?api-version=$version" |
            Where-Object { $_.name -notin @('GetPayment','ExplainHold') })
        if ($customTools.Count) { throw "Export or remove the custom tools from $managedName before stopping the gateway." }
    }
    $otherApis = @($apis | Where-Object { $_.properties.type -ne 'mcp' -and
        $_.name -notin @('minibank-payments','minibank-payments;rev=1') })
    if ($otherApis.Count) {
        throw "Additional API(s) found on the Developer gateway: $($otherApis.name -join ', '). Export or remove them before stopping."
    }
    if ($servers.Count -eq 0) {
        if (Test-Path -LiteralPath $Archive) {
            $prior = Get-Content -Raw -LiteralPath $Archive | ConvertFrom-Json -AsHashtable -Depth 100
            if (@($prior.servers | Where-Object { $_.name -ne $managedName }).Count) {
                throw "There are no manually managed MCP servers on the gateway but $Archive has a snapshot. Reconcile or move the archive before stopping."
            }
        }
        Write-Output 'No manually managed MCP servers to capture.'
        return
    }
    $snapshot = foreach ($server in $servers) {
        $path = "$base/apis/$($server.name)"
        $properties = (Read-Arm "$($path)?api-version=$version").properties
        if ($properties.type -ne 'mcp' -or $properties.serviceUrl -or $properties.subscriptionRequired -or
            $properties.apiVersionSetId -or $properties.authenticationSettings -and
            @($properties.authenticationSettings.Values | Where-Object { $_ }).Count) {
            throw "MCP server $($server.name) must be a REST API-backed server with Entra policy, no subscriptions, and no version set."
        }
        if (@(Read-Collection "$path/products?api-version=2024-05-01").Count) {
            throw "MCP server $($server.name) has product bindings. Remove them or export their configuration before stopping."
        }
        $tools = @(Read-Collection "$path/tools?api-version=$version" | ForEach-Object {
            if ($_.properties.operationId -notlike "$ServiceId/apis/minibank-payments/operations/*") {
                throw "Unexpected backing operation for tool $($_.name)."
            }
            @{ name = $_.name; properties = Select-Properties $_.properties @('displayName','description','operationId') }
        })
        if (!$tools.Count) { throw "MCP server $($server.name) has no tools to capture. Finish the portal configuration before stopping." }
        $policy = (Read-Arm "$path/policies/policy?api-version=$version&format=rawxml" -Optional).properties
        if ($policy.value -and !([xml]$policy.value).SelectSingleNode('/policies/inbound/*[1][self::base]')) {
            throw "MCP policy $($server.name) must inherit the gateway authentication policy first."
        }
        @{
            name = $server.name
            properties = Select-Properties $properties @('type','path','displayName','description','protocols','subscriptionRequired','mcpProperties')
            tools = $tools
            policy = if ($policy.value) { @{ format='rawxml'; value=$policy.value } }
        }
    }
    $data = @{ schema = 1; serviceId = $ServiceId; servers = @($snapshot) } | ConvertTo-Json -Depth 100
    $temp = "$Archive.$([guid]::NewGuid()).tmp"
    [IO.File]::WriteAllText($temp, $data)
    [IO.File]::Move($temp, $Archive, $true)
    Write-Output "Captured $($servers.Count) MCP server(s) in $Archive."
    return
}

if (!(Test-Path -LiteralPath $Archive)) { return }
$backup = Get-Content -Raw -LiteralPath $Archive | ConvertFrom-Json -AsHashtable -Depth 100
if ($backup.schema -ne 1 -or $backup.serviceId -ine $ServiceId) { throw 'MCP archive belongs to a different gateway or format.' }
foreach ($server in $backup.servers) {
    if ($server.name -eq $managedName) {
        Write-Warning "Skipping archived $managedName. Terraform manages that server and its two tools."
        continue
    }
    $path = "$base/apis/$($server.name)"
    $current = $servers | Where-Object name -eq $server.name
    if (!$current) {
        Set-Arm "$($path)?api-version=$version" $server.properties
    }
    if ($server.policy -and !(Read-Arm "$path/policies/policy?api-version=$version&format=rawxml" -Optional)) {
        Set-Arm "$path/policies/policy?api-version=$version" $server.policy
    }
    foreach ($tool in $server.tools) {
        $toolUri = "$path/tools/$($tool.name)?api-version=$version"
        if (!(Read-Arm $toolUri -Optional)) { Set-Arm $toolUri $tool.properties }
        if ((Read-Arm $toolUri).properties.operationId -ine $tool.properties.operationId) {
            throw "MCP tool $($tool.name) exists with a different operation."
        }
    }
    Write-Output "Verified MCP server and tool bindings for $($server.name)."
}
