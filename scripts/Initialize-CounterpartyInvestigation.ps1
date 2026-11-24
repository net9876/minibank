[CmdletBinding()]
param(
    [Parameter(Mandatory)] [uri] $EnvironmentUrl,
    [Parameter(Mandatory)] [guid] $TenantId,
    [switch] $Apply
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
if ($EnvironmentUrl.Scheme -ne 'https' -or $EnvironmentUrl.Host -notmatch '\.crm[0-9]*\.dynamics\.com$' -or
    $EnvironmentUrl.AbsolutePath -ne '/' -or $EnvironmentUrl.Query -or $EnvironmentUrl.UserInfo) {
    throw 'Specify the HTTPS origin of MiniBank-Lab.'
}
$origin = $EnvironmentUrl.GetLeftPart([UriPartial]::Authority)
$token = az account get-access-token --tenant $TenantId --resource $origin --query accessToken -o tsv --only-show-errors
$auth = @{
    Authentication='Bearer'; Token=(ConvertTo-SecureString $token -AsPlainText -Force)
    Headers=@{'OData-Version'='4.0';Accept='application/json';'MSCRM.SolutionUniqueName'='MiniBankLab'}
}
$base = "$origin/api/data/v9.2"
$caller = Invoke-RestMethod @auth -Uri "$base/WhoAmI"
$solution = (Invoke-RestMethod @auth -Uri "$base/solutions?%24select=uniquename,ismanaged&%24filter=uniquename%20eq%20'MiniBankLab'").value
if (@($solution).Count -ne 1 -or $solution.ismanaged) { throw 'The unmanaged MiniBankLab solution is required.' }
$lookup = "$base/EntityDefinitions?%24select=LogicalName,EntitySetName,IsOptimisticConcurrencyEnabled&%24filter=LogicalName%20eq%20'mbank_counterpartyinvestigation'"
$requestLookup = $lookup.Replace('mbank_counterpartyinvestigation','mbank_counterpartyrequest')
$table = (Invoke-RestMethod @auth -Uri $lookup).value
$requestTable = (Invoke-RestMethod @auth -Uri $requestLookup).value
function Label($text) { @{ LocalizedLabels=@(@{Label=$text;LanguageCode=1033}) } }

if (!$Apply) {
    [ordered]@{ user=$caller.UserId; solution='MiniBankLab';
        investigation=if ($table) {'verify'} else {'create'};
        request=if ($requestTable) {'verify'} else {'create'} } | ConvertTo-Json
    return
}
if (!$requestTable) {
    $definition = @{
        '@odata.type'='Microsoft.Dynamics.CRM.EntityMetadata'
        SchemaName='mbank_CounterpartyRequest'
        DisplayName=Label 'Counterparty Request'
        DisplayCollectionName=Label 'Counterparty Requests'
        Description=Label 'Operator submissions to the MiniBank counterparty investigation.'
        OwnershipType='UserOwned'
        HasActivities=$false
        HasNotes=$false
        IsActivity=$false
        Attributes=@(
            @{ '@odata.type'='Microsoft.Dynamics.CRM.StringAttributeMetadata'; SchemaName='mbank_Name';
               DisplayName=Label 'Request Name'; IsPrimaryName=$true; FormatName=@{Value='Text'}; MaxLength=100 },
            @{ '@odata.type'='Microsoft.Dynamics.CRM.StringAttributeMetadata'; SchemaName='mbank_RequestStatus';
               DisplayName=Label 'Request Status'; FormatName=@{Value='Text'}; MaxLength=40 },
            @{ '@odata.type'='Microsoft.Dynamics.CRM.MemoAttributeMetadata'; SchemaName='mbank_RequestJson';
               DisplayName=Label 'Request Input'; MaxLength=2000 }
        )
    }
    $null = Invoke-RestMethod @auth -Uri "$base/EntityDefinitions" -Method Post -ContentType 'application/json' -Body ($definition | ConvertTo-Json -Depth 20) -TimeoutSec 120
    $requestTable = (Invoke-RestMethod @auth -Uri $requestLookup).value
}

if (!$table) {
    $definition = @{
        '@odata.type'='Microsoft.Dynamics.CRM.EntityMetadata'
        SchemaName='mbank_CounterpartyInvestigation'
        DisplayName=Label 'Counterparty Investigation'
        DisplayCollectionName=Label 'Counterparty Investigations'
        Description=Label 'MiniBank counterparty request, approval and evidence.'
        OwnershipType='UserOwned'
        HasActivities=$false
        HasNotes=$false
        IsActivity=$false
        Attributes=@(
            @{ '@odata.type'='Microsoft.Dynamics.CRM.StringAttributeMetadata'; SchemaName='mbank_Name';
               DisplayName=Label 'Investigation Name'; IsPrimaryName=$true; FormatName=@{Value='Text'}; MaxLength=100 },
            @{ '@odata.type'='Microsoft.Dynamics.CRM.StringAttributeMetadata'; SchemaName='mbank_Status';
               DisplayName=Label 'Investigation Status'; FormatName=@{Value='Text'}; MaxLength=40 },
            @{ '@odata.type'='Microsoft.Dynamics.CRM.MemoAttributeMetadata'; SchemaName='mbank_StateJson';
               DisplayName=Label 'Investigation Evidence'; MaxLength=100000 }
        )
    }
    $null = Invoke-RestMethod @auth -Uri "$base/EntityDefinitions" -Method Post -ContentType 'application/json' -Body ($definition | ConvertTo-Json -Depth 20) -TimeoutSec 120
    $table = (Invoke-RestMethod @auth -Uri $lookup).value
}
if (@($table).Count -ne 1 -or !$table.IsOptimisticConcurrencyEnabled) {
    throw 'The investigation table must support optimistic concurrency.'
}
$columns = (Invoke-RestMethod @auth -Uri "$base/EntityDefinitions(LogicalName='mbank_counterpartyinvestigation')/Attributes?%24select=LogicalName").value.LogicalName
foreach($field in @('mbank_name','mbank_status','mbank_statejson')){
    if($field -notin $columns){throw "Investigation table is missing $field."}
}
if (@($requestTable).Count -ne 1 -or !$requestTable.IsOptimisticConcurrencyEnabled) {
    throw 'The request table must support optimistic concurrency.'
}
[ordered]@{user=$caller.UserId;solution='MiniBankLab';entitySet=$table.EntitySetName;requestSet=$requestTable.EntitySetName;optimisticConcurrency=$true} | ConvertTo-Json
