param(
  [Parameter(Mandatory = $true)][string]$SubscriptionId,
  [Parameter(Mandatory = $true)][string]$ResourceGroupName,
  [string]$Location = "",
  [string]$NamePrefix = "reccia",
  [string]$SearchServiceName = "",
  [string]$DocumentIntelligenceAccountName = "",
  [string]$VisionAccountName = "",
  [string]$OpenAIAccountName = "",
  [string]$OpenAIDeploymentName = "gpt-4.1-mini",
  [string]$OpenAIModelName = "gpt-4.1-mini",
  [string]$OpenAIModelVersion = "2025-04-14"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$regionFinder = Join-Path $PSScriptRoot "find-deployment-regions.ps1"

az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) {
  throw "Subscription '$SubscriptionId' is not available in the current Azure CLI login."
}

$regionParameters = @{
  SubscriptionId = $SubscriptionId
  ModelName = $OpenAIModelName
  ModelVersion = $OpenAIModelVersion
}
if ($Location) {
  $regionParameters.Regions = @($Location)
}

$eligibleRegion = & $regionFinder @regionParameters
$Location = $eligibleRegion.Region
Write-Host "Using Azure region '$Location' for Flex Consumption and $OpenAIModelName $OpenAIModelVersion."

az group create --name $ResourceGroupName --location $Location | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "Creating resource group '$ResourceGroupName' in '$Location' failed."
}

$bicepPath = Join-Path $repo "infra\main.bicep"
if (Test-Path $bicepPath) {
  az deployment group create `
    --resource-group $ResourceGroupName `
    --template-file $bicepPath `
    --parameters `
      namePrefix=$NamePrefix `
      location=$Location `
      searchServiceName=$SearchServiceName `
      documentIntelligenceAccountName=$DocumentIntelligenceAccountName `
      visionAccountName=$VisionAccountName `
      openAIAccountName=$OpenAIAccountName `
      openAIDeploymentName=$OpenAIDeploymentName `
      openAIModelName=$OpenAIModelName `
      openAIModelVersion=$OpenAIModelVersion
  exit $LASTEXITCODE
}

if (-not $SearchServiceName) { $SearchServiceName = "$NamePrefix-search-$((New-Guid).Guid.Substring(0, 6))" }
if (-not $DocumentIntelligenceAccountName) { $DocumentIntelligenceAccountName = "$NamePrefix-docintel-$((New-Guid).Guid.Substring(0, 6))" }
if (-not $VisionAccountName) { $VisionAccountName = "$NamePrefix-vision-$((New-Guid).Guid.Substring(0, 6))" }
if (-not $OpenAIAccountName) { $OpenAIAccountName = "$NamePrefix-openai-$((New-Guid).Guid.Substring(0, 6))" }

if (-not (az search service show --resource-group $ResourceGroupName --name $SearchServiceName --query name -o tsv 2>$null)) {
  az search service create --resource-group $ResourceGroupName --name $SearchServiceName --location $Location --sku basic --partition-count 1 --replica-count 1 | Out-Null
}

foreach ($account in @(
  @{ Name = $DocumentIntelligenceAccountName; Kind = "FormRecognizer"; Sku = "S0" },
  @{ Name = $VisionAccountName; Kind = "ComputerVision"; Sku = "S1" }
)) {
  if (-not (az cognitiveservices account show --resource-group $ResourceGroupName --name $account.Name --query name -o tsv 2>$null)) {
    az cognitiveservices account create `
      --resource-group $ResourceGroupName `
      --name $account.Name `
      --location $Location `
      --kind $account.Kind `
      --sku $account.Sku `
      --yes | Out-Null
  }
  az cognitiveservices account update `
    --resource-group $ResourceGroupName `
    --name $account.Name `
    --set properties.disableLocalAuth=true | Out-Null
}

if (-not (az cognitiveservices account show --resource-group $ResourceGroupName --name $OpenAIAccountName --query name -o tsv 2>$null)) {
  $bodyPath = Join-Path $env:TEMP "$OpenAIAccountName-account.json"
  @{
    location = $Location
    kind = "OpenAI"
    sku = @{ name = "S0" }
    identity = @{ type = "SystemAssigned" }
    properties = @{
      customSubDomainName = $OpenAIAccountName
      disableLocalAuth = $true
      publicNetworkAccess = "Enabled"
    }
  } | ConvertTo-Json -Depth 10 | Set-Content -Path $bodyPath -Encoding utf8

  az rest `
    --method put `
    --uri "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.CognitiveServices/accounts/$OpenAIAccountName`?api-version=2023-05-01" `
    --body "@$bodyPath" | Out-Null
}

if (-not (az cognitiveservices account deployment list --resource-group $ResourceGroupName --name $OpenAIAccountName --query "[?name=='$OpenAIDeploymentName'].name | [0]" -o tsv 2>$null)) {
  $deploymentPath = Join-Path $env:TEMP "$OpenAIDeploymentName-deployment.json"
  @{
    sku = @{ name = "Standard"; capacity = 10 }
    properties = @{ model = @{ format = "OpenAI"; name = $OpenAIModelName; version = $OpenAIModelVersion } }
  } | ConvertTo-Json -Depth 10 | Set-Content -Path $deploymentPath -Encoding utf8

  az rest `
    --method put `
    --uri "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.CognitiveServices/accounts/$OpenAIAccountName/deployments/$OpenAIDeploymentName`?api-version=2023-05-01" `
    --body "@$deploymentPath" | Out-Null
}

[PSCustomObject]@{
  resourceGroup = $ResourceGroupName
  location = $Location
  searchService = $SearchServiceName
  documentIntelligenceAccount = $DocumentIntelligenceAccountName
  visionAccount = $VisionAccountName
  openAIAccount = $OpenAIAccountName
  openAIDeployment = $OpenAIDeploymentName
} | ConvertTo-Json
