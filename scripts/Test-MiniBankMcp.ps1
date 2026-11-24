[CmdletBinding()]
param(
    [Parameter(Mandatory)] [uri] $Endpoint,
    [securestring] $AccessToken
)

$ErrorActionPreference = 'Stop'
if ($Endpoint.Scheme -ne 'https' -or $Endpoint.Host -notmatch '^minibank-mcp-[0-9a-f]{12}\.azure-api\.net$' -or
    $Endpoint.AbsolutePath -ne '/payment-investigation/mcp') {
    throw 'Use the Terraform endpoint for the MiniBank Developer gateway.'
}
$headers = @{ Accept = 'application/json, text/event-stream' }
$init = @{
    jsonrpc = '2.0'; id = 1; method = 'initialize'
    params = @{ protocolVersion = '2025-06-18'; capabilities = @{}; clientInfo = @{name='minibank-smoke';version='1.0'} }
}
$requestOptions = @{
    Uri=$Endpoint; Method='Post'; ContentType='application/json'; SkipHttpErrorCheck=$true; TimeoutSec=45
    MaximumRedirection=0
}
for ($attempt = 0; $attempt -lt 8; $attempt++) {
    $anonymous = Invoke-WebRequest @requestOptions -Headers $headers -Body ($init | ConvertTo-Json -Depth 15 -Compress)
    if ($anonymous.StatusCode -notin @(404, 503)) { break }
    if ($attempt -lt 7) { Start-Sleep -Seconds 5 }
}
if ($anonymous.StatusCode -ne 401) { throw "Anonymous MCP initialize expected HTTP 401 and got $($anonymous.StatusCode)." }
Write-Output 'MCP rejected anonymous initialize with HTTP 401.'
if (!$AccessToken) { return }

function Send-Mcp($request) {
    $body = $request | ConvertTo-Json -Depth 15 -Compress
    $response = Invoke-WebRequest @requestOptions -Headers $headers -Authentication Bearer -Token $AccessToken -Body $body
    if ($response.StatusCode -notin @(200, 202, 204)) { throw "$($request.method) returned HTTP $($response.StatusCode)." }
    $returnedSession = if ($response.Headers) { @($response.Headers['Mcp-Session-Id'])[0] }
    if ($returnedSession) { $headers['Mcp-Session-Id'] = $returnedSession }
    if (!$request.ContainsKey('id')) { return }

    $contentType = @($response.Headers['Content-Type'])[0]
    if ($contentType -like 'text/event-stream*') {
        $messages = @($response.Content -split '\r?\n\r?\n' | ForEach-Object {
            $data = ($_ -split '\r?\n' | Where-Object { $_.StartsWith('data:') } | ForEach-Object { $_.Substring(5).TrimStart() }) -join [Environment]::NewLine
            if ($data) { $data | ConvertFrom-Json -AsHashtable -Depth 100 }
        })
        $message = $messages | Where-Object id -eq $request.id | Select-Object -First 1
    } else {
        $message = $response.Content | ConvertFrom-Json -AsHashtable -Depth 100
    }
    if (!$message -or $message.id -ne $request.id -or $message.error -or !$message.Contains('result')) {
        throw "$($request.method) returned an invalid MCP response."
    }
    $message.result
}

$initialization = Send-Mcp $init
if (!$initialization.protocolVersion) { throw 'The MCP server did not negotiate a protocol version.' }
$headers['MCP-Protocol-Version'] = $initialization.protocolVersion
Send-Mcp @{ jsonrpc='2.0'; method='notifications/initialized' }

$tools = (Send-Mcp @{ jsonrpc='2.0'; id=2; method='tools/list'; params=@{} }).tools
$names = @($tools | ForEach-Object { $_.name } | Sort-Object)
if (($names -join ',') -cne 'ExplainHold,GetPayment') { throw "Expected exactly ExplainHold and GetPayment; got $($names -join ', ')." }
Write-Output 'Authenticated MCP initialization and tools/list passed.'

$id = 2
foreach ($name in @('GetPayment','ExplainHold')) {
    $id++
    $result = Send-Mcp @{
        jsonrpc='2.0'; id=$id; method='tools/call'
        params=@{ name=$name; arguments=@{ paymentId='PAY-1030' } }
    }
    if ($result.isError) { throw "$name returned a tool error for PAY-1030." }
    $text = @($result.content | Where-Object type -eq 'text' | ForEach-Object { $_.text }) -join [Environment]::NewLine
    $payload = if ($result.structuredContent) { $result.structuredContent } else { $text | ConvertFrom-Json -AsHashtable -Depth 100 }
    if (!$payload.found -or $payload.paymentId -ne 'PAY-1030') { throw "$name did not return PAY-1030." }
    if ($name -eq 'GetPayment' -and $payload.reasonCode -ne 'PAYMENT_REVIEW') { throw 'Unexpected PAY-1030 hold reason.' }
    if ($name -eq 'ExplainHold' -and (!$payload.policyFound -or $payload.source.policyId -ne 'MB-PAY-002' -or
        $payload.source.version -ne '1.0' -or $payload.source.sectionId -ne 'review-payment' -or
        [string]::IsNullOrWhiteSpace($payload.source.excerpt))) { throw 'Unexpected PAY-1030 policy citation or empty excerpt.' }
    Write-Output "$name passed for PAY-1030."
}
