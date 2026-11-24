[CmdletBinding(DefaultParameterSetName = 'Subscription')]
param(
    [Parameter(Mandatory)] [uri] $EnvironmentUrl,
    [Parameter(Mandatory, ParameterSetName = 'Subscription')] [guid] $SubscriptionId,
    [Parameter(Mandatory, ParameterSetName = 'Tenant')] [guid] $TenantId
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$env:AZURE_LOGGING_ENABLE_LOG_FILE = 'false'
$env:AZURE_CORE_COLLECT_TELEMETRY = 'false'
if ($EnvironmentUrl.Scheme -ne 'https' -or $EnvironmentUrl.Host -notmatch '\.crm[0-9]*\.dynamics\.com$' -or
    $EnvironmentUrl.AbsolutePath -ne '/' -or $EnvironmentUrl.Query -or $EnvironmentUrl.UserInfo) {
    throw 'Specify the HTTPS origin of the MiniBank-Lab Dataverse environment.'
}
$origin = $EnvironmentUrl.GetLeftPart([UriPartial]::Authority)
$api = "$origin/api/data/v9.2"
$accountArguments = if ($PSCmdlet.ParameterSetName -eq 'Tenant') {
    @('--tenant', $TenantId.ToString())
} else {
    @('--subscription', $SubscriptionId.ToString())
}
$token = az account get-access-token @accountArguments --resource $origin `
    --query accessToken -o tsv --only-show-errors
$headers = @{
    Authorization = "Bearer $token"
    'OData-Version' = '4.0'
    'OData-MaxVersion' = '4.0'
    Accept = 'application/json'
}

function Invoke-Dataverse {
    param([string] $Method, [string] $Path, [hashtable] $Body)
    Write-Verbose "$Method $Path"
    $timeout = if ($Method -eq 'Post' -and $Path -eq 'EntityDefinitions') { 120 } else { 35 }
    $parameters = @{ Method = $Method; Uri = "$api/$Path"; Headers = $headers; TimeoutSec = $timeout }
    if ($Body) {
        $parameters.ContentType = 'application/json; charset=utf-8'
        $parameters.Body = $Body | ConvertTo-Json -Depth 20 -Compress
    }
    Invoke-RestMethod @parameters
}

function New-Label([string] $Text) {
    @{ LocalizedLabels = @(@{ Label = $Text; LanguageCode = 1033 }) }
}

$null = Invoke-Dataverse -Method Get -Path 'WhoAmI'
$publisher = (Invoke-Dataverse Get "publishers?%24select=publisherid&%24filter=uniquename%20eq%20'minibank'").value
if (!$publisher) {
    $null = Invoke-Dataverse Post 'publishers' @{
        uniquename = 'minibank'; friendlyname = 'MiniBank Lab'; customizationprefix = 'mbank'
    }
    $publisher = (Invoke-Dataverse Get "publishers?%24select=publisherid&%24filter=uniquename%20eq%20'minibank'").value
}
$solution = (Invoke-Dataverse Get "solutions?%24select=solutionid&%24filter=uniquename%20eq%20'MiniBankLab'").value
if (!$solution) {
    $null = Invoke-Dataverse Post 'solutions' @{
        uniquename = 'MiniBankLab'; friendlyname = 'MiniBank Lab'; version = '1.0.0.0'
        'publisherid@odata.bind' = "/publishers($($publisher.publisherid))"
    }
}
$headers['MSCRM.SolutionUniqueName'] = 'MiniBankLab'
$tablePath = "EntityDefinitions(LogicalName='mbank_reviewcase')"
$table = (Invoke-Dataverse Get "EntityDefinitions?%24select=LogicalName,EntitySetName&%24filter=LogicalName%20eq%20'mbank_reviewcase'").value
if (!$table) {
    $null = Invoke-Dataverse Post 'EntityDefinitions' @{
        '@odata.type' = 'Microsoft.Dynamics.CRM.EntityMetadata'
        SchemaName = 'mbank_ReviewCase'
        DisplayName = New-Label 'Review Case'
        DisplayCollectionName = New-Label 'Review Cases'
        Description = New-Label 'MiniBank operational investigations.'
        OwnershipType = 'UserOwned'
        HasActivities = $false
        HasNotes = $false
        IsActivity = $false
        Attributes = @(
            @{
                '@odata.type' = 'Microsoft.Dynamics.CRM.StringAttributeMetadata'
                SchemaName = 'mbank_CaseNumber'
                DisplayName = New-Label 'Case Number'
                IsPrimaryName = $true
                FormatName = @{ Value = 'Text' }
                MaxLength = 50
                AutoNumberFormat = 'CASE-{SEQNUM:6}'
            },
            @{
                '@odata.type' = 'Microsoft.Dynamics.CRM.StringAttributeMetadata'
                SchemaName = 'mbank_PaymentId'
                DisplayName = New-Label 'Payment ID'
                FormatName = @{ Value = 'Text' }
                MaxLength = 32
                RequiredLevel = @{ Value = 'ApplicationRequired' }
            },
            @{
                '@odata.type' = 'Microsoft.Dynamics.CRM.MemoAttributeMetadata'
                SchemaName = 'mbank_Resolution'
                DisplayName = New-Label 'Resolution'
                MaxLength = 4000
            }
        )
    }
}

$keyPath = "$tablePath/Keys"
$keyQuery = "${keyPath}?%24select=SchemaName,EntityKeyIndexStatus&%24filter=SchemaName%20eq%20'mbank_PaymentIdKey'"
if (!(Invoke-Dataverse Get $keyQuery).value) {
    $null = Invoke-Dataverse Post $keyPath @{
        '@odata.type' = 'Microsoft.Dynamics.CRM.EntityKeyMetadata'
        SchemaName = 'mbank_PaymentIdKey'
        DisplayName = New-Label 'Payment ID'
        KeyAttributes = @('mbank_paymentid')
    }
}

$deadline = [datetime]::UtcNow.AddMinutes(3)
do {
    $key = (Invoke-Dataverse Get $keyQuery).value | Select-Object -First 1
    if ($key.EntityKeyIndexStatus -in @('Active', 'Failed')) { break }
    Start-Sleep -Seconds 5
} while ([datetime]::UtcNow -lt $deadline)
if ($key.EntityKeyIndexStatus -ne 'Active') { throw "Payment ID alternate key status is $($key.EntityKeyIndexStatus)." }
$table = Invoke-Dataverse Get "${tablePath}?%24select=EntitySetName"
$count = Invoke-Dataverse Get "$($table.EntitySetName)/%24count"
$rowCount = [int]([string]$count).TrimStart([char]0xFEFF).Trim()
[ordered]@{ solution = 'MiniBankLab'; table = $table.EntitySetName; alternateKey = 'Active'; rowCount = $rowCount } |
    ConvertTo-Json -Compress
