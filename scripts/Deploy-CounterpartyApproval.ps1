[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Plan','Apply','Enable')] [string] $Action,
    [Parameter(Mandatory)] [guid] $ApproverObjectId,
    [Parameter(Mandatory)] [System.Net.Mail.MailAddress] $Approver,
    [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z0-9-]+$')] [string] $ApprovalsConnection,
    [Parameter(Mandatory)] [ValidatePattern('^[a-zA-Z0-9-]+$')] [string] $DataverseConnection
)

$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$true
$origin='https://orgf038e181.crm.dynamics.com'
$tenant='d5b48ebd-83f6-48f0-8910-983b68fd884a'
$token=az account get-access-token --tenant $tenant --resource $origin --query accessToken -o tsv --only-show-errors
$auth=@{Authentication='Bearer';Token=ConvertTo-SecureString $token -AsPlainText -Force}
$base="$origin/api/data/v9.2"
$name='MiniBank Counterparty - Teams Approval'
$marker='Managed by the MiniBank counterparty approval deployment.'
$dvRef='new_sharedcommondataserviceforapps_7ed90'
$apRef='mbank_MiniBankCounterpartyApprovals'
$dvApi='shared_commondataserviceforapps'
$apApi='shared_approvals'
$prefix='/providers/Microsoft.PowerApps/apis/'
$headers=@{'MSCRM.SolutionUniqueName'='MiniBankLab';'OData-Version'='4.0'}

function Find-Row($collection,$filter,$columns) {
    $url="$base/$collection"+"?%24filter="+[uri]::EscapeDataString($filter)+"&%24select="+[uri]::EscapeDataString($columns)
    $rows=@((Invoke-RestMethod @auth -Uri $url).value | Where-Object {$_})
    if($rows.Count -gt 1){throw "Ambiguous configuration for $collection."}
    if($rows.Count){$rows[0]}
}
function Write-Row($method,$path,$data,$extra=@{}) {
    Invoke-WebRequest @auth -Method $method -Uri "$base/$path" -Headers ($headers+$extra) -ContentType 'application/json' -Body ($data | ConvertTo-Json -Depth 90 -Compress)
}
function Ref-Body($api,$logical,$connection) {
    @{impersonation=@{};runtimeSource='embedded';connection=@{name=$connection;connectionReferenceLogicalName=$logical};api=@{name=$api}}
}
$solution=Find-Row 'solutions' "uniquename eq 'MiniBankLab'" 'uniquename,ismanaged'
if (!$solution -or $solution.ismanaged) { throw 'Expected the unmanaged MiniBankLab solution.' }
$dv=Find-Row 'connectionreferences' "connectionreferencelogicalname eq '$dvRef'" 'connectionid,connectorid'
if (!$dv -or $dv.connectorid -ne "$prefix$dvApi" -or ($dv.connectionid -split '/')[-1] -ne $DataverseConnection) {
    throw 'The existing Dataverse reference does not match the verified connection.'
}
$ap=Find-Row 'connectionreferences' "connectionreferencelogicalname eq '$apRef'" 'connectionid,connectorid'
if ($ap -and ($ap.connectorid -ne "$prefix$apApi" -or ($ap.connectionid -split '/')[-1] -ne $ApprovalsConnection)) {
    throw 'The Approvals connection reference already points elsewhere.'
}
$filter="category eq 5 and name eq '$name'"
$existing=Find-Row 'workflows' $filter 'workflowid,statecode,description,clientdata'
if($existing -and $existing.description -ne $marker) { throw 'An unrelated workflow already uses this name.' }

$template=Join-Path $PSScriptRoot '../counterparty/power-platform/approval-flow.json'
$definition=(Get-Content -LiteralPath $template -Raw).Replace('__APPROVER_ID__',$ApproverObjectId.ToString()).Replace('__APPROVER_UPN__',$Approver.Address).Replace('__TENANT_ID__',$tenant) | ConvertFrom-Json -AsHashtable
$document=@{schemaVersion='1.0.0.0'; properties=@{connectionReferences=@{
    $dvApi=Ref-Body $dvApi $dvRef $DataverseConnection
    $apApi=Ref-Body $apApi $apRef $ApprovalsConnection
};definition=$definition}} | ConvertTo-Json -Depth 90 -Compress

if($Action -eq 'Plan'){
    [ordered]@{flow=$name;environment=$origin;approver=$Approver.Address;existingId=$existing.workflowid;
      approvalReference=if($ap){'reuse'}else{'create'}} | ConvertTo-Json
    return
}
if($Action -eq 'Apply'){
    if(!$ap){
        $null=Write-Row Post 'connectionreferences' @{
            connectionreferencelogicalname=$apRef;connectionreferencedisplayname='MiniBank Counterparty Approvals'
            connectorid="$prefix$apApi";connectionid=$ApprovalsConnection
        }
    }
    if(!$existing){
        $null=Write-Row Post 'workflows' @{category=5;type=1;name=$name;primaryentity='none';description=$marker;clientdata=$document}
    } elseif($existing.statecode -eq 0){
        $null=Write-Row Patch "workflows($($existing.workflowid))" @{clientdata=$document} @{'If-Match'=$existing.'@odata.etag'}
    }
} else {
    if(!$existing -or !$ap){throw 'Apply the draft before enabling.'}
    if($existing.statecode -eq 0){
        $null=Write-Row Patch "workflows($($existing.workflowid))" @{statecode=1;statuscode=2} @{'If-Match'=$existing.'@odata.etag'}
    }
}
Find-Row 'workflows' $filter 'workflowid,statecode,name' | ConvertTo-Json
