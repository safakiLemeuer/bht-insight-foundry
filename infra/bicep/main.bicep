targetScope = 'resourceGroup'

@description('Azure region. Keep Foundry, Azure AI Search, and the application in the same region when supported.')
param location string = resourceGroup().location

@description('Deployment environment name.')
@allowed([
  'dev'
  'test'
  'prod'
])
param environment string = 'dev'

@description('Short globally unique suffix, lowercase letters and numbers only.')
@minLength(3)
@maxLength(8)
param uniqueSuffix string

@description('Whether to deploy model deployments. Set false until model availability and quota are verified in the target region.')
param deployModels bool = false

@description('Chat model name available in the selected region.')
param chatModelName string = 'gpt-4.1-mini'

@description('Chat model version available in the selected region.')
param chatModelVersion string = ''

@description('Chat model deployment capacity in thousands of tokens per minute for Standard SKU.')
@minValue(1)
param chatModelCapacity int = 10

@description('Embedding model name supported by Azure AI Search integrated vectorization.')
param embeddingModelName string = 'text-embedding-3-small'

@description('Embedding model version available in the selected region.')
param embeddingModelVersion string = '1'

@description('Embedding model deployment capacity in thousands of tokens per minute for Standard SKU.')
@minValue(1)
param embeddingModelCapacity int = 10

@description('Linux App Service Plan SKU.')
param appServicePlanSku string = 'B1'

@description('Azure AI Search SKU. Basic or higher is required for managed identity outbound connections.')
@allowed([
  'basic'
  'standard'
])
param searchSku string = 'basic'

var workload = 'bhtinsight'
var compactPrefix = '${workload}${environment}${uniqueSuffix}'
var standardPrefix = '${workload}-${environment}-${uniqueSuffix}'
var tags = {
  application: 'BHT Insight Foundry'
  environment: environment
  managedBy: 'Bicep'
  phase: '1A'
  dataClassification: 'Demonstration'
}

var storageName = take(replace('st${compactPrefix}', '-', ''), 24)
var keyVaultName = take('kv-${standardPrefix}', 24)
var foundryName = take('ai-${standardPrefix}', 64)
var foundryProjectName = take('proj-${standardPrefix}', 64)
var searchName = take('srch-${standardPrefix}', 60)
var appServicePlanName = 'asp-${standardPrefix}'
var webAppName = take('app-${standardPrefix}', 60)
var logAnalyticsName = 'log-${standardPrefix}'
var appInsightsName = 'appi-${standardPrefix}'

// Built-in role definition IDs.
var storageBlobDataReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
var searchIndexDataReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1407120a-92aa-4202-b7e9-c0e197c71c8f')
var cognitiveServicesOpenAIUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
var keyVaultSecretsUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    retentionInDays: environment == 'prod' ? 90 : 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    DisableIpMasking: false
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  name: 'default'
  parent: storage
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource approvedContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: 'documents-approved'
  parent: blobService
  properties: {
    publicAccess: 'None'
  }
}

resource quarantineContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: 'documents-quarantine'
  parent: blobService
  properties: {
    publicAccess: 'None'
  }
}

resource rejectedContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: 'documents-rejected'
  parent: blobService
  properties: {
    publicAccess: 'None'
  }
}

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: foundryName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: foundryName
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
    restrictOutboundNetworkAccess: false
  }
}

resource foundryProject 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  name: foundryProjectName
  parent: foundry
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: 'BHT Insight Phase 1A'
    description: 'Foundry project for the BHT Insight end-to-end RAG web application.'
  }
}

resource chatDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = if (deployModels) {
  name: 'chat-bht-insight'
  parent: foundry
  sku: {
    name: 'Standard'
    capacity: chatModelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: chatModelName
      version: chatModelVersion
    }
    versionUpgradeOption: 'OnceCurrentVersionExpired'
  }
}

resource embeddingDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = if (deployModels) {
  name: 'embed-bht-insight'
  parent: foundry
  sku: {
    name: 'Standard'
    capacity: embeddingModelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: embeddingModelName
      version: embeddingModelVersion
    }
    versionUpgradeOption: 'OnceCurrentVersionExpired'
  }
}

resource search 'Microsoft.Search/searchServices@2023-11-01' = {
  name: searchName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: searchSku
  }
  properties: {
    authOptions: {
      aadOrApiKey: {
        aadAuthFailureMode: 'http401WithBearerChallenge'
      }
    }
    disableLocalAuth: true
    encryptionWithCmk: {
      enforcement: 'Unspecified'
    }
    hostingMode: 'default'
    partitionCount: 1
    publicNetworkAccess: 'Enabled'
    replicaCount: environment == 'prod' ? 2 : 1
    semanticSearch: 'free'
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    enableRbacAuthorization: true
    enablePurgeProtection: environment == 'prod'
    enableSoftDelete: true
    publicNetworkAccess: 'Enabled'
    sku: {
      family: 'A'
      name: 'standard'
    }
    softDeleteRetentionInDays: 7
  }
}

resource appServicePlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: appServicePlanName
  location: location
  tags: tags
  kind: 'linux'
  sku: {
    name: appServicePlanSku
  }
  properties: {
    reserved: true
    zoneRedundant: false
  }
}

resource webApp 'Microsoft.Web/sites@2024-04-01' = {
  name: webAppName
  location: location
  tags: tags
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    siteConfig: {
      alwaysOn: appServicePlanSku != 'F1'
      ftpsState: 'Disabled'
      http20Enabled: true
      linuxFxVersion: 'PYTHON|3.12'
      minimumElasticInstanceCount: 0
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      use32BitWorkerProcess: false
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'ApplicationInsightsAgent_EXTENSION_VERSION'
          value: '~3'
        }
        {
          name: 'AZURE_AI_FOUNDRY_ENDPOINT'
          value: foundry.properties.endpoint
        }
        {
          name: 'AZURE_AI_FOUNDRY_PROJECT_NAME'
          value: foundryProject.name
        }
        {
          name: 'AZURE_OPENAI_CHAT_DEPLOYMENT'
          value: 'chat-bht-insight'
        }
        {
          name: 'AZURE_OPENAI_EMBEDDING_DEPLOYMENT'
          value: 'embed-bht-insight'
        }
        {
          name: 'AZURE_SEARCH_ENDPOINT'
          value: 'https://${search.name}.search.windows.net'
        }
        {
          name: 'AZURE_SEARCH_INDEX'
          value: 'bht-insight-chunks'
        }
        {
          name: 'AZURE_STORAGE_ACCOUNT_URL'
          value: 'https://${storage.name}.blob.core.windows.net'
        }
        {
          name: 'AZURE_STORAGE_APPROVED_CONTAINER'
          value: approvedContainer.name
        }
        {
          name: 'KEY_VAULT_URL'
          value: keyVault.properties.vaultUri
        }
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'true'
        }
      ]
    }
  }
}

// Search indexer reads approved documents from Blob Storage.
resource searchStorageReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, search.id, storageBlobDataReaderRoleId)
  scope: storage
  properties: {
    principalId: search.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageBlobDataReaderRoleId
  }
}

// Search integrated vectorization calls the Foundry-hosted embedding deployment.
resource searchFoundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundry.id, search.id, cognitiveServicesOpenAIUserRoleId)
  scope: foundry
  properties: {
    principalId: search.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: cognitiveServicesOpenAIUserRoleId
  }
}

// Runtime web app queries Azure AI Search.
resource webSearchReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, webApp.id, searchIndexDataReaderRoleId)
  scope: search
  properties: {
    principalId: webApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: searchIndexDataReaderRoleId
  }
}

// Runtime web app calls the chat and embedding model endpoints without API keys.
resource webFoundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundry.id, webApp.id, cognitiveServicesOpenAIUserRoleId)
  scope: foundry
  properties: {
    principalId: webApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: cognitiveServicesOpenAIUserRoleId
  }
}

// Runtime web app can read approved documents for citation/source display.
resource webStorageReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, webApp.id, storageBlobDataReaderRoleId)
  scope: storage
  properties: {
    principalId: webApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageBlobDataReaderRoleId
  }
}

resource webKeyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, webApp.id, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    principalId: webApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: keyVaultSecretsUserRoleId
  }
}

output foundryAccountName string = foundry.name
output foundryProjectName string = foundryProject.name
output foundryEndpoint string = foundry.properties.endpoint
output searchServiceName string = search.name
output searchEndpoint string = 'https://${search.name}.search.windows.net'
output storageAccountName string = storage.name
output approvedContainerName string = approvedContainer.name
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output webAppName string = webApp.name
output webAppUrl string = 'https://${webApp.properties.defaultHostName}'
output webAppPrincipalId string = webApp.identity.principalId
output searchPrincipalId string = search.identity.principalId
output applicationInsightsName string = appInsights.name
output logAnalyticsWorkspaceName string = logAnalytics.name
