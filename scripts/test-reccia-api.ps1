param(
  [Parameter(Mandatory = $true)][string]$SubscriptionId,
  [Parameter(Mandatory = $true)][string]$ResourceGroupName,
  [Parameter(Mandatory = $true)][string]$FunctionAppName,
  [string]$Question = "Show me diagrams related to solar permitting workflows and required checklist steps."
)

$ErrorActionPreference = "Stop"
az account set --subscription $SubscriptionId

$key = az functionapp keys list `
  --resource-group $ResourceGroupName `
  --name $FunctionAppName `
  --query functionKeys.default `
  -o tsv

$hostName = az resource show `
  --resource-group $ResourceGroupName `
  --name $FunctionAppName `
  --resource-type Microsoft.Web/sites `
  --api-version 2024-04-01 `
  --query properties.defaultHostName `
  -o tsv

if (-not $hostName) {
  throw "Function hostname was empty."
}

$body = @{
  question = $Question
  topDocuments = 4
  topImages = 4
} | ConvertTo-Json

Invoke-RestMethod `
  -Method Post `
  -Uri "https://$hostName/api/askrenewablecompliance" `
  -Headers @{ "x-functions-key" = $key; "Content-Type" = "application/json" } `
  -Body $body

