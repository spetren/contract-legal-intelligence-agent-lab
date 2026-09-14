targetScope = 'resourceGroup'

@description('Short lowercase prefix used for resource names.')
@minLength(2)
@maxLength(12)
param namePrefix string = 'reccia'

@description('Azure region for all supported resources.')
param location string = resourceGroup().location

@description('Azure AI Search service name. Leave blank to derive from namePrefix and unique resource group hash.')
param searchServiceName string = ''

@description('Document Intelligence account name. Leave blank to derive from namePrefix and unique resource group hash.')
param documentIntelligenceAccountName string = ''

@description('Azure AI Vision account name. Leave blank to derive from namePrefix and unique resource group hash.')
param visionAccountName string = ''

@description('Azure OpenAI account name. Leave blank to derive from namePrefix and unique resource group hash.')
param openAIAccountName string = ''

@description('Azure OpenAI chat deployment name used by the Function app.')
param openAIDeploymentName string = 'gpt-4.1-mini'

@description('Azure OpenAI model name.')
param openAIModelName string = 'gpt-4.1-mini'

@description('Azure OpenAI model version.')
param openAIModelVersion string = '2025-04-14'

@description('Storage account name for the Azure Function app. Must be globally unique, 3-24 lowercase alphanumeric characters.')
param storageAccountName string = ''

@description('Azure Function app name. Leave blank to derive from namePrefix and unique resource group hash.')
param functionAppName string = ''

@description('Azure AI Search SKU.')
@allowed([
  'basic'
  'standard'
])
param searchSku string = 'basic'

@description('Azure AI Search replica count.')
@minValue(1)
param searchReplicaCount int = 1

@description('Azure AI Search partition count.')
@minValue(1)
param searchPartitionCount int = 1

@description('Text chunk index name.')
param documentIndexName string = 'reccia-documents'

@description('Image/visual evidence index name.')
param imageIndexName string = 'reccia-images'

var suffix = toLower(take(uniqueString(resourceGroup().id), 6))
var searchName = empty(searchServiceName) ? '${namePrefix}-search-${suffix}' : searchServiceName
var docIntelName = empty(documentIntelligenceAccountName) ? '${namePrefix}-docintelrg-reccia-lab-${suffix}' : documentIntelligenceAccountName
var visionName = empty(visionAccountName) ? '${namePrefix}-vision-${suffix}' : visionAccountName
var openAIName = empty(openAIAccountName) ? '${namePrefix}-openai-${suffix}' : openAIAccountName
var functionName = empty(functionAppName) ? '${namePrefix}-agent-api-${suffix}' : functionAppName
var storageName = empty(storageAccountName) ? take(replace('${namePrefix}fn${suffix}', '-', ''), 24) : storageAccountName
var appInsightsName = '${functionName}-appi'

resource searchService 'Microsoft.Search/searchServices@2023-11-01' = {
  name: searchName
  location: location
  sku: {
    name: searchSku
  }
  properties: {
    replicaCount: searchReplicaCount
    partitionCount: searchPartitionCount
    hostingMode: 'default'
    publicNetworkAccess: 'enabled'
    disableLocalAuth: false
    authOptions: {
      apiKeyOnly: {}
    }
  }
}

resource documentIntelligence 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: docIntelName
  location: location
  kind: 'FormRecognizer'
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: docIntelName
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
  }
}

resource vision 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: visionName
  location: location
  kind: 'ComputerVision'
  sku: {
    name: 'S1'
  }
  properties: {
    customSubDomainName: visionName
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
  }
}

resource openAI 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: openAIName
  location: location
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: openAIName
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
  }
}

resource openAIDeployment 'Microsoft.CognitiveServices/accounts/deployments@2023-05-01' = {
  parent: openAI
  name: openAIDeploymentName
  sku: {
    name: 'Standard'
    capacity: 10
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: openAIModelName
      version: openAIModelVersion
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
    raiPolicyName: 'Microsoft.DefaultV2'
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Disabled'
  }
}

module functionHosting 'function-app-flex.bicep' = {
  name: 'function-hosting'
  params: {
    location: location
    functionAppName: functionName
    storageAccountName: storage.name
    appInsightsName: appInsightsName
    searchEndpoint: 'https://${searchService.name}.search.windows.net'
    documentIndexName: documentIndexName
    imageIndexName: imageIndexName
    openAIAccountName: openAI.name
    openAIEndpoint: openAI.properties.endpoint
    openAIDeploymentName: openAIDeployment.name
  }
}

output searchServiceName string = searchService.name
output documentIntelligenceAccountName string = documentIntelligence.name
output visionAccountName string = vision.name
output openAIAccountName string = openAI.name
output openAIDeploymentName string = openAIDeployment.name
output storageAccountName string = storage.name
output functionAppName string = functionHosting.outputs.functionAppName
output functionApiUrl string = functionHosting.outputs.functionApiUrl
output documentIndexName string = documentIndexName
output imageIndexName string = imageIndexName

