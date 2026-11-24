[CmdletBinding()]
param(
    [Parameter(Mandatory)] [guid] $SubscriptionId,
    [Parameter(Mandatory)] [string] $StorageAccount,
    [string] $Container = 'policy-library'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$env:AZURE_LOGGING_ENABLE_LOG_FILE = 'false'
$env:AZURE_CORE_COLLECT_TELEMETRY = 'false'

$library = Join-Path $PSScriptRoot '..\data\policy-library'
$manifestPath = Join-Path $library 'manifest.json'
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$content = @($manifest.documents | ForEach-Object {
    @{ Path = $_.path; ContentType = 'text/markdown; charset=utf-8'; Overwrite = 'false' }
})
$content += @{ Path = 'manifest.json'; ContentType = 'application/json'; Overwrite = 'true' }

$existing = @{}
$blobs = az storage blob list -c $Container --account-name $StorageAccount --subscription $SubscriptionId `
    --auth-mode login --include m --query '[].{name:name,sha:metadata.minibanksha256}' --only-show-errors -o json | ConvertFrom-Json
foreach ($blob in $blobs) { $existing[$blob.name] = $blob.sha }
$expected = @{}
foreach ($item in $content) {
    $path = Join-Path $library $item.Path
    $sha = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    $expected[$item.Path] = $sha
    if ($existing[$item.Path] -eq $sha) { continue }
    if ($item.Overwrite -eq 'false' -and $existing.ContainsKey($item.Path)) {
        throw "Policy version $($item.Path) already exists with different content. Publish changes under a new version."
    }
    az storage blob upload -f $path -n $item.Path -c $Container --account-name $StorageAccount `
        --subscription $SubscriptionId --auth-mode login --content-type $item.ContentType `
        --overwrite $item.Overwrite --metadata "minibanksha256=$sha" --only-show-errors -o none
}
$published = az storage blob list -c $Container --account-name $StorageAccount --subscription $SubscriptionId `
    --auth-mode login --include m --query '[].{name:name,sha:metadata.minibanksha256}' --only-show-errors -o json | ConvertFrom-Json
foreach ($name in $expected.Keys) {
    if (!($published | Where-Object { $_.name -ceq $name -and $_.sha -ceq $expected[$name] })) {
        throw "Blob verification failed for $name."
    }
}
$expected.Keys | Sort-Object
