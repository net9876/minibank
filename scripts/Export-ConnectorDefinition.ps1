[CmdletBinding()]
param([Parameter(Mandatory)] [string] $OutputPath)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$infra = Join-Path $PSScriptRoot '..\infra'
$operations = terraform "-chdir=$infra" output -json operations | ConvertFrom-Json
if (!$operations.gateway_url -or !$operations.api_app_client_id -or !$operations.tenant_id) {
    throw 'Apply the Operations infrastructure plan first.'
}
$gateway = [uri] $operations.gateway_url
$issuer = "https://login.microsoftonline.com/$($operations.tenant_id)/oauth2/v2.0"
$scope = "api://$($operations.api_app_client_id)/Payments.Read"
$openapi = Get-Content -Raw -LiteralPath (Join-Path $infra 'operations\openapi.json') | ConvertFrom-Json -AsHashtable
$paths = [ordered]@{}

foreach ($path in $openapi.paths.Keys) {
    $operation = $openapi.paths[$path].get
    $responses = [ordered]@{}
    foreach ($code in $operation.responses.Keys) {
        $response = $operation.responses[$code]
        $responses[$code] = @{
            description = $response.description
            schema = $response.content['application/json'].schema
        }
    }
    $paths[$path] = @{
        get = @{
            summary = $operation.summary
            operationId = $operation.operationId
            parameters = @($operation.parameters | ForEach-Object {
                @{ name = $_.name; in = $_.in; required = $_.required; type = $_.schema.type }
            })
            responses = $responses
        }
    }
}

$swagger = [ordered]@{
    swagger = '2.0'
    info = $openapi.info
    host = $gateway.Host
    basePath = $gateway.AbsolutePath
    schemes = @('https')
    produces = @('application/json')
    paths = $paths
    definitions = $openapi.components.schemas
    securityDefinitions = @{
        OAuth = @{
            type = 'oauth2'
            flow = 'accessCode'
            authorizationUrl = "$issuer/authorize"
            tokenUrl = "$issuer/token"
            scopes = @{ $scope = 'Read MiniBank payments and guidance' }
        }
    }
    security = @(@{ OAuth = @($scope) })
}

$definition = $swagger | ConvertTo-Json -Depth 30
$definition = $definition.Replace('#/components/schemas/', '#/definitions/')
$definition = $definition.Replace('"nullable":', '"x-nullable":')
Set-Content -LiteralPath $OutputPath -Value $definition -Encoding utf8
Write-Output (Get-Item -LiteralPath $OutputPath).FullName
