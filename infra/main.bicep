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
var docIntelName = empty(documentIntelligenceAccountName) ? '${namePrefix}-docintel-${suffix}' : documentIntelligenceAccountName
var visionName = empty(visionAccountName) ? '${namePrefix}-vision-${suffix}' : visionAccountName
var openAIName = empty(openAIAccountName) ? '${namePrefix}-openai-${suffix}' : openAIAccountName
var functionName = empty(functionAppName) ? '${namePrefix}-agent-api-${suffix}' : functionAppName
var storageName = empty(storageAccountName) ? take(replace('${namePrefix}fn${suffix}', '-', ''), 24) : storageAccountName
var appInsightsName = '${functionName}-appi'
var hostingPlanName = '${functionName}-plan'

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
    allowSharedKeyAccess: true
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: hostingPlanName
  location: location
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    httpsOnly: true
    serverFarmId: plan.id
    siteConfig: {
      linuxFxVersion: 'Python|3.11'
      appSettings: [
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storage.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storage.listKeys().keys[0].value}'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'SEARCH_ENDPOINT'
          value: 'https://${searchService.name}.search.windows.net'
        }
        {
          name: 'DOCUMENT_INDEX'
          value: documentIndexName
        }
        {
          name: 'IMAGE_INDEX'
          value: imageIndexName
        }
        {
          name: 'AZURE_OPENAI_ENDPOINT'
          value: openAI.properties.endpoint
        }
        {
          name: 'AZURE_OPENAI_DEPLOYMENT'
          value: openAIDeploymentName
        }
        {
          name: 'AZURE_OPENAI_API_VERSION'
          value: '2024-10-21'
        }
      ]
    }
  }
}

resource openAIUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(openAI.id, functionApp.id, 'Cognitive Services OpenAI User')
  scope: openAI
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output searchServiceName string = searchService.name
output documentIntelligenceAccountName string = documentIntelligence.name
output visionAccountName string = vision.name
output openAIAccountName string = openAI.name
output openAIDeploymentName string = openAIDeployment.name
output storageAccountName string = storage.name
output functionAppName string = functionApp.name
output functionApiUrl string = 'https://${functionApp.properties.defaultHostName}/api/askrenewablecompliance'
output documentIndexName string = documentIndexName
output imageIndexName string = imageIndexName

