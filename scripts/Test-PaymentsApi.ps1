[CmdletBinding()]
param([Parameter(Mandatory)] [securestring] $AccessToken)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$infra = Join-Path $PSScriptRoot '..\infra'
$operations = terraform "-chdir=$infra" output -json operations | ConvertFrom-Json
if (!$operations.gateway_url) { throw 'Deploy the operations infrastructure first.' }
$base = $operations.gateway_url

function Get-PaymentResponse([string] $Path, [int] $ExpectedStatus) {
    $requestHeaders = @{ 'x-correlation-id' = "check-$([guid]::NewGuid().ToString('N'))" }
    $response = Invoke-WebRequest -Uri "$base/$Path" -Authentication Bearer -Token $AccessToken `
        -Headers $requestHeaders -SkipHttpErrorCheck -TimeoutSec 35
    if ([int] $response.StatusCode -ne $ExpectedStatus) {
        throw "GET $Path returned $($response.StatusCode), expected $ExpectedStatus."
    }
    if ($response.Headers['x-correlation-id'][0] -ne $requestHeaders['x-correlation-id']) {
        throw "GET $Path returned an incorrect correlation ID."
    }
    $response.Content | ConvertFrom-Json
}

$payment = Get-PaymentResponse 'payments/PAY-1042' 200
if (!$payment.found -or $payment.status -cne 'On hold' -or
    $payment.reasonCode -cne 'BEN_VERIFICATION' -or
    $payment.holdReason -cne 'Beneficiary details pending verification' -or
    $payment.currency -cne 'USD' -or $payment.amount -cne '250.0000' -or $payment.events.Count -ne 2) {
    throw 'PAY-1042 did not match the control fixture.'
}
$unknown = Get-PaymentResponse 'payments/PAY-UNKNOWN' 404
if ($unknown.found -ne $false) { throw '404 response did not map to found=false.' }
$guidance = Get-PaymentResponse 'payments/PAY-1042/guidance' 200
if (!$guidance.policyFound -or !$guidance.recommendation -or
    $guidance.source.policyId -cne 'MB-BEN-001' -or $guidance.source.version -cne '1.0' -or
    $guidance.source.sectionId -cne 'verify-beneficiary') {
    throw 'Guidance did not cite the fixture policy section.'
}
Write-Output 'PAY-1042, PAY-UNKNOWN, policy citation and correlation verified.'
