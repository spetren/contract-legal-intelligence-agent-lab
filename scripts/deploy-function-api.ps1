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
$flexTemplate = Join-Path $repo "infra\function-app-flex.bicep"

function Assert-AzSuccess {
  param([Parameter(Mandatory = $true)][string]$Operation)
  if ($LASTEXITCODE -ne 0) {
    throw "$Operation failed with Azure CLI exit code $LASTEXITCODE."
  }
}

az account set --subscription $SubscriptionId
Assert-AzSuccess "Selecting subscription"

az provider register --namespace Microsoft.App --wait
Assert-AzSuccess "Registering Microsoft.App"

if (-not (az storage account show --resource-group $ResourceGroupName --name $StorageAccountName --query name -o tsv 2>$null)) {
  az storage account create `
    --resource-group $ResourceGroupName `
    --name $StorageAccountName `
    --location $Location `
    --sku Standard_LRS `
    --kind StorageV2 `
    --min-tls-version TLS1_2 `
    --allow-blob-public-access false | Out-Null
  Assert-AzSuccess "Creating storage account"
}

$existingApp = az functionapp show `
  --resource-group $ResourceGroupName `
  --name $FunctionAppName `
  -o json 2>$null | ConvertFrom-Json

if ($existingApp) {
  $existingPlanId = $existingApp.appServicePlanId
  if (-not $existingPlanId) {
    $existingPlanId = az resource show `
      --resource-group $ResourceGroupName `
      --name $FunctionAppName `
      --resource-type Microsoft.Web/sites `
      --api-version 2024-04-01 `
      --query properties.serverFarmId `
      -o tsv
    Assert-AzSuccess "Reading Function hosting plan"
  }
  $existingPlanName = Split-Path -Leaf $existingPlanId
  $existingPlanSku = az appservice plan show `
    --resource-group $ResourceGroupName `
    --name $existingPlanName `
    --query sku.name `
    -o tsv 2>$null

  if ($existingPlanSku -and $existingPlanSku -ne "FC1") {
    Write-Host "Replacing incompatible $existingPlanSku Function hosting with Flex Consumption."
    az functionapp delete --resource-group $ResourceGroupName --name $FunctionAppName | Out-Null
    Assert-AzSuccess "Deleting incompatible Function App"
    az appservice plan delete --resource-group $ResourceGroupName --name $existingPlanName --yes | Out-Null
    Assert-AzSuccess "Deleting incompatible hosting plan"
  }
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

az deployment group create `
  --resource-group $ResourceGroupName `
  --template-file $flexTemplate `
  --parameters `
    location=$Location `
    functionAppName=$FunctionAppName `
    storageAccountName=$StorageAccountName `
    appInsightsName="$FunctionAppName-appi" `
    searchEndpoint="https://$SearchServiceName.search.windows.net" `
    documentIndexName=$DocumentIndexName `
    imageIndexName=$ImageIndexName `
    openAIAccountName=$OpenAIAccountName `
    openAIEndpoint=$openAiEndpoint `
    openAIDeploymentName=$OpenAIDeploymentName | Out-Null
  Assert-AzSuccess "Deploying Flex Consumption infrastructure"

  $integrationSubnetId = az network vnet subnet show `
    --resource-group $ResourceGroupName `
    --vnet-name "$FunctionAppName-vnet" `
    --name "function-integration" `
    --query id `
    -o tsv
  Assert-AzSuccess "Reading Function integration subnet"

  az functionapp vnet-integration add `
    --resource-group $ResourceGroupName `
    --name $FunctionAppName `
    --vnet "$FunctionAppName-vnet" `
    --subnet $integrationSubnetId | Out-Null
  Assert-AzSuccess "Attaching Function VNet integration"

az functionapp config appsettings set `
  --resource-group $ResourceGroupName `
  --name $FunctionAppName `
  --settings `
    "SEARCH_QUERY_KEY=$queryKey" | Out-Null
  Assert-AzSuccess "Configuring Function settings"

az functionapp config appsettings delete `
  --resource-group $ResourceGroupName `
  --name $FunctionAppName `
  --setting-names SCM_DO_BUILD_DURING_DEPLOYMENT ENABLE_ORYX_BUILD | Out-Null
Assert-AzSuccess "Removing legacy build settings"

az functionapp update `
  --resource-group $ResourceGroupName `
  --name $FunctionAppName `
  --set httpsOnly=true | Out-Null
Assert-AzSuccess "Enabling HTTPS-only access"

$packageDir = Join-Path $env:TEMP "reccia-agent-api-package"
$zip = Join-Path $env:TEMP "reccia-agent-api.zip"
if (Test-Path $packageDir) { Remove-Item $packageDir -Recurse -Force }
if (Test-Path $zip) { Remove-Item $zip -Force }
New-Item -ItemType Directory -Path $packageDir | Out-Null
Copy-Item -Path (Join-Path $apiDir "*") -Destination $packageDir -Recurse -Force

python -m pip install `
  --disable-pip-version-check `
  --target (Join-Path $packageDir ".python_packages\lib\site-packages") `
  --requirement (Join-Path $apiDir "requirements.txt") | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "Packaging Python dependencies failed with exit code $LASTEXITCODE."
}

Compress-Archive -Path (Join-Path $packageDir "*") -DestinationPath $zip -Force

az functionapp deployment source config-zip `
  --resource-group $ResourceGroupName `
  --name $FunctionAppName `
  --src $zip `
  --build-remote false | Out-Null
Assert-AzSuccess "Deploying Function package"

$hostName = az resource show `
  --resource-group $ResourceGroupName `
  --name $FunctionAppName `
  --resource-type Microsoft.Web/sites `
  --api-version 2024-04-01 `
  --query properties.defaultHostName `
  -o tsv
Assert-AzSuccess "Reading Function hostname"
if (-not $hostName) {
  throw "Function hostname was empty."
}

[PSCustomObject]@{
  functionApp = $FunctionAppName
  apiUrl = "https://$hostName/api/askrenewablecompliance"
  openApi = Join-Path $apiDir "copilot-studio-openapi.yaml"
} | ConvertTo-Json

