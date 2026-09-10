param(
  [Parameter(Mandatory = $true)][string]$SubscriptionId,
  [Parameter(Mandatory = $true)][string]$ResourceGroupName,
  [Parameter(Mandatory = $true)][string]$FunctionAppName,
  [Parameter(Mandatory = $true)][string]$EnvironmentUrl,
  [Parameter(Mandatory = $true)][string]$EnvironmentId,
  [Parameter(Mandatory = $true)][string]$BotSchemaName,
  [string]$TenantId = "",
  [string]$ConnectionName = "reccia-renewable-knowledge",
  [string]$ConnectorDisplayName = "Renewable Compliance Knowledge"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$connectorDir = Join-Path $repo "reccia-agent-api\connector"

az account set --subscription $SubscriptionId
$functionKey = az functionapp keys list `
  --resource-group $ResourceGroupName `
  --name $FunctionAppName `
  --query functionKeys.default `
  -o tsv

$dataverseUrl = $EnvironmentUrl.TrimEnd("/")
$dataverseToken = az account get-access-token --resource $dataverseUrl --query accessToken -o tsv
$dataverseHeaders = @{
  Authorization = "Bearer $dataverseToken"
  Accept = "application/json"
  "Content-Type" = "application/json"
  "OData-MaxVersion" = "4.0"
  "OData-Version" = "4.0"
}

$connector = (Invoke-RestMethod `
  -Uri "$dataverseUrl/api/data/v9.2/connectors?`$select=connectorid,displayname,connectorinternalid&`$filter=displayname eq '$ConnectorDisplayName'&`$orderby=createdon desc" `
  -Headers $dataverseHeaders).value | Select-Object -First 1

if (-not $connector) {
  $definitionTemplate = Get-Content (Join-Path $connectorDir "apiDefinition.swagger.json") -Raw
  $definition = $definitionTemplate -replace '"host"\s*:\s*"[^"]+"', "`"host`": `"$FunctionAppName.azurewebsites.net`""
  $definitionPath = Join-Path $env:TEMP "reccia-apiDefinition.$FunctionAppName.swagger.json"
  $definition | Set-Content -Path $definitionPath -Encoding utf8

  pac connector create `
    --environment $EnvironmentUrl `
    --api-definition-file $definitionPath `
    --api-properties-file (Join-Path $connectorDir "apiProperties.json")

  $connector = (Invoke-RestMethod `
    -Uri "$dataverseUrl/api/data/v9.2/connectors?`$select=connectorid,displayname,connectorinternalid&`$filter=displayname eq '$ConnectorDisplayName'&`$orderby=createdon desc" `
    -Headers $dataverseHeaders).value | Select-Object -First 1
}

if (-not $connector) {
  throw "Could not find the '$ConnectorDisplayName' custom connector in Dataverse."
}

$connectorInternalId = $connector.connectorinternalid
$connectorPath = "/providers/Microsoft.PowerApps/apis/$connectorInternalId"

Import-Module Microsoft.PowerApps.PowerShell -Force
if ($TenantId) {
  Add-PowerAppsAccount -Endpoint prod -TenantID $TenantId | Out-Null
} else {
  Add-PowerAppsAccount -Endpoint prod | Out-Null
}

$connectionRoute = "https://{powerAppsEndpoint}/providers/Microsoft.PowerApps/apis/$connectorInternalId/connections/$ConnectionName`?api-version=2016-11-01&`$filter=environment%20eq%20%27$EnvironmentId%27"
$connectionBody = @{
  properties = @{
    apiId = $connectorPath
    displayName = $ConnectorDisplayName
    environment = @{
      id = "/providers/Microsoft.PowerApps/environments/$EnvironmentId"
      name = $EnvironmentId
    }
    connectionParameters = @{
      api_key = $functionKey
    }
  }
}

InvokeApi -Method PUT -Route $connectionRoute -Body $connectionBody -ApiVersion "2016-11-01" | Out-Null

$connectionReferenceLogicalName = "$BotSchemaName.$connectorInternalId.$ConnectionName"
$existing = (Invoke-RestMethod `
  -Uri "$dataverseUrl/api/data/v9.2/connectionreferences?`$select=connectionreferenceid&`$filter=connectionreferencelogicalname eq '$connectionReferenceLogicalName'" `
  -Headers $dataverseHeaders).value | Select-Object -First 1

if (-not $existing) {
  $body = @{
    connectionreferencelogicalname = $connectionReferenceLogicalName
    connectionreferencedisplayname = "$ConnectorDisplayName Connection Reference"
    connectorid = $connectorPath
    "CustomConnectorId@odata.bind" = "/connectors($($connector.connectorid))"
    connectionid = $ConnectionName
    promptingbehavior = 0
  } | ConvertTo-Json -Depth 10

  Invoke-RestMethod -Method Post `
    -Uri "$dataverseUrl/api/data/v9.2/connectionreferences" `
    -Headers $dataverseHeaders `
    -Body $body | Out-Null
} else {
  $body = @{ connectionid = $ConnectionName } | ConvertTo-Json
  Invoke-RestMethod -Method Patch `
    -Uri "$dataverseUrl/api/data/v9.2/connectionreferences($($existing.connectionreferenceid))" `
    -Headers $dataverseHeaders `
    -Body $body | Out-Null
}

[PSCustomObject]@{
  connectorId = $connector.connectorid
  connectorInternalId = $connectorInternalId
  connectionName = $ConnectionName
  connectionReferenceLogicalName = $connectionReferenceLogicalName
} | ConvertTo-Json
