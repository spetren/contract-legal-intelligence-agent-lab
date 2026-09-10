param(
  [Parameter(Mandatory = $true)][string]$SubscriptionId,
  [Parameter(Mandatory = $true)][string]$ResourceGroupName,
  [Parameter(Mandatory = $true)][string]$FunctionAppName,
  [Parameter(Mandatory = $true)][string]$StorageAccountName,
  [Parameter(Mandatory = $true)][string]$SearchServiceName,
  [Parameter(Mandatory = $true)][string]$OpenAIAccountName,
  [string]$OpenAIDeploymentName = "gpt-4.1-mini",
  [string]$Location = "eastus",
  [string]$DocumentIndexName = "reccia-documents",
  [string]$ImageIndexName = "reccia-images"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$apiDir = Join-Path $repo "reccia-agent-api"

az account set --subscription $SubscriptionId

if (-not (az storage account show --resource-group $ResourceGroupName --name $StorageAccountName --query name -o tsv 2>$null)) {
  az storage account create `
    --resource-group $ResourceGroupName `
    --name $StorageAccountName `
    --location $Location `
    --sku Standard_LRS `
    --kind StorageV2 `
    --min-tls-version TLS1_2 `
    --allow-blob-public-access false | Out-Null
}

if (-not (az functionapp show --resource-group $ResourceGroupName --name $FunctionAppName --query name -o tsv 2>$null)) {
  az functionapp create `
    --resource-group $ResourceGroupName `
    --name $FunctionAppName `
    --storage-account $StorageAccountName `
    --consumption-plan-location $Location `
    --runtime python `
    --runtime-version 3.11 `
    --functions-version 4 `
    --os-type Linux `
    --assign-identity | Out-Null
}

$queryKey = az search query-key list `
  --resource-group $ResourceGroupName `
  --service-name $SearchServiceName `
  --query "[?name=='reccia-agent-api'].key | [0]" `
  -o tsv

if (-not $queryKey) {
  $queryKey = az search query-key create `
    --resource-group $ResourceGroupName `
    --service-name $SearchServiceName `
    --name "reccia-agent-api" `
    --query key `
    -o tsv
}

$openAiEndpoint = az cognitiveservices account show `
  --resource-group $ResourceGroupName `
  --name $OpenAIAccountName `
  --query properties.endpoint `
  -o tsv

$principalId = az functionapp identity show `
  --resource-group $ResourceGroupName `
  --name $FunctionAppName `
  --query principalId `
  -o tsv

$openAiId = az cognitiveservices account show `
  --resource-group $ResourceGroupName `
  --name $OpenAIAccountName `
  --query id `
  -o tsv

az role assignment create `
  --assignee-object-id $principalId `
  --assignee-principal-type ServicePrincipal `
  --role "Cognitive Services OpenAI User" `
  --scope $openAiId | Out-Null

az functionapp config appsettings set `
  --resource-group $ResourceGroupName `
  --name $FunctionAppName `
  --settings `
    "SEARCH_ENDPOINT=https://$SearchServiceName.search.windows.net" `
    "SEARCH_QUERY_KEY=$queryKey" `
    "DOCUMENT_INDEX=$DocumentIndexName" `
    "IMAGE_INDEX=$ImageIndexName" `
    "AZURE_OPENAI_ENDPOINT=$openAiEndpoint" `
    "AZURE_OPENAI_DEPLOYMENT=$OpenAIDeploymentName" `
    "AZURE_OPENAI_API_VERSION=2024-10-21" | Out-Null

az functionapp update `
  --resource-group $ResourceGroupName `
  --name $FunctionAppName `
  --set httpsOnly=true | Out-Null

$zip = Join-Path $env:TEMP "reccia-agent-api.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $apiDir "*") -DestinationPath $zip -Force

az functionapp deployment source config-zip `
  --resource-group $ResourceGroupName `
  --name $FunctionAppName `
  --src $zip `
  --build-remote true | Out-Null

$hostName = az functionapp show `
  --resource-group $ResourceGroupName `
  --name $FunctionAppName `
  --query defaultHostName `
  -o tsv

[PSCustomObject]@{
  functionApp = $FunctionAppName
  apiUrl = "https://$hostName/api/askrenewablecompliance"
  openApi = Join-Path $apiDir "copilot-studio-openapi.yaml"
} | ConvertTo-Json

