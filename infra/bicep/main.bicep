targetScope = 'resourceGroup'

@description('Primary Azure region for Foundry, Functions, storage, observability, and the demo web tier.')
param location string = resourceGroup().location

@description('Azure AI Search region. Defaults to the primary region but can be overridden when regional Search capacity is constrained.')
param searchLocation string = location

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

@description('Whether to deploy model deployments. Keep false until regional model availability and quota are verified.')
param deployModels bool = false

@description('Chat model name available in the selected region.')
param chatModelName string = 'gpt-4.1-mini'

@description('Chat model version. Supply an available version when deployModels is true.')
param chatModelVersion string = ''

@description('Chat model Standard deployment capacity in thousands of tokens per minute.')
@minValue(1)
param chatModelCapacity int = 10

@description('Embedding model name.')
param embeddingModelName string = 'text-embedding-3-small'

@description('Embedding model version. Supply an available version when deployModels is true.')
param embeddingModelVersion string = '1'

@description('Embedding model Standard deployment capacity in thousands of tokens per minute.')
@minValue(1)
param embeddingModelCapacity int = 10

@description('Azure AI Search SKU.')
@allowed([
  'basic'
  'standard'
])
param searchSku string = 'basic'

@description('Python version for the Azure Functions Flex Consumption runtime. Verify the version in the target region before deployment.')
param functionPythonVersion string = '3.12'

@description('Maximum Flex Consumption instances. Keep intentionally low for the Phase 1A development environment.')
@minValue(1)
@maxValue(1000)
param functionMaximumInstanceCount int = 20

@description('Memory allocated to each Flex Consumption instance in MB.')
@allowed([
  512
  2048
  4096
])
param functionInstanceMemoryMB int = 2048

var workload = 'bhtinsight'
var compactPrefix = '${workload}${environment}${uniqueSuffix}'
var standardPrefix = '${workload}-${environment}-${uniqueSuffix}'
var tags = {
  application: 'BHT Insight Foundry'
  environment: environment
  managedBy: 'Bicep'
  phase: '1A'
  hostingModel: 'Serverless'
  dataClassification: 'Demonstration'
}

var knowledgeStorageName = take(replace('st${compactPrefix}', '-', ''), 24)
var functionStorageName = take(replace('stfn${compactPrefix}', '-', ''), 24)
var keyVaultName = take('kv-${standardPrefix}', 24)
var foundryName = take('ai-${standardPrefix}', 64)
var foundryProjectName = take('proj-${standardPrefix}', 64)
var searchName = take('srch-${standardPrefix}', 60)
var functionPlanName = take('fc-${standardPrefix}', 40)
var functionAppName = take('func-${standardPrefix}', 60)
var staticWebAppName = take('swa-${standardPrefix}', 60)
var logAnalyticsName = 'log-${standardPrefix}'
var appInsightsName = 'appi-${standardPrefix}'

// Azure built-in role definition IDs.
var storageBlobDataReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
var storageBlobDataOwnerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
var searchIndexDataReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '1407120a-92aa-4202-b7e9-c0e197c71c8f')
var cognitiveServicesOpenAIUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
var keyVaultSecretsUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
var monitoringMetricsPublisherRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')

// -----------------------------------------------------------------------------
// Observability
// -----------------------------------------------------------------------------
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

// -----------------------------------------------------------------------------
// Enterprise knowledge storage. This account stores approved source documents.
// It is intentionally separate from the Azure Functions runtime storage.
// -----------------------------------------------------------------------------
resource knowledgeStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: knowledgeStorageName
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
    allowSharedKeyAccess: false
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

resource knowledgeBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  name: 'default'
  parent: knowledgeStorage
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
  parent: knowledgeBlobService
  properties: {
    publicAccess: 'None'
  }
}

resource quarantineContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: 'documents-quarantine'
  parent: knowledgeBlobService
  properties: {
    publicAccess: 'None'
  }
}

resource rejectedContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: 'documents-rejected'
  parent: knowledgeBlobService
  properties: {
    publicAccess: 'None'
  }
}

// -----------------------------------------------------------------------------
// Dedicated Functions runtime/deployment storage. Keeping this separate reduces
// accidental coupling between application-runtime data and enterprise content.
// -----------------------------------------------------------------------------
resource functionStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: functionStorageName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
  }
}

resource functionBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  name: 'default'
  parent: functionStorage
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: 'deployments'
  parent: functionBlobService
  properties: {
    publicAccess: 'None'
  }
}

// -----------------------------------------------------------------------------
// Microsoft Foundry account and project.
// -----------------------------------------------------------------------------
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
    description: 'Foundry project for the BHT Insight serverless RAG web application.'
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

// -----------------------------------------------------------------------------
// Azure AI Search for hybrid/vector RAG retrieval. Search can be placed in a
// separate region from the rest of the demo when capacity is constrained.
// -----------------------------------------------------------------------------
resource search 'Microsoft.Search/searchServices@2023-11-01' = {
  name: searchName
  location: searchLocation
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: searchSku
  }
  properties: {
    disableLocalAuth: true
    encryptionWithCmk: {
      enforcement: 'Unspecified'
    }
    hostingMode: 'default'
    partitionCount: 1
    publicNetworkAccess: 'enabled'
    replicaCount: environment == 'prod' ? 2 : 1
    semanticSearch: 'free'
  }
}

// -----------------------------------------------------------------------------
// Key Vault is present only for integrations that cannot use managed identity.
// The Phase 1A Azure-to-Azure path itself is keyless.
// Purge protection is enabled only for prod; omitting the property in dev/test
// preserves easy cleanup because the service rejects an explicit false value.
// -----------------------------------------------------------------------------
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    publicNetworkAccess: 'Enabled'
    sku: {
      family: 'A'
      name: 'standard'
    }
    softDeleteRetentionInDays: 7
    ...(environment == 'prod' ? {
      enablePurgeProtection: true
    } : {})
  }
}

// -----------------------------------------------------------------------------
// Serverless API: Azure Functions Flex Consumption. FC1 is not the dedicated B1
// App Service SKU that caused the Phase 1A quota block.
// -----------------------------------------------------------------------------
resource functionPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: functionPlanName
  location: location
  tags: tags
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: functionPlan.id
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${functionStorage.properties.primaryEndpoints.blob}${deploymentContainer.name}'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: functionMaximumInstanceCount
        instanceMemoryMB: functionInstanceMemoryMB
      }
      runtime: {
        name: 'python'
        version: functionPythonVersion
      }
    }
    siteConfig: {
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      http20Enabled: true
      appSettings: [
        {
          name: 'AzureWebJobsStorage__accountName'
          value: functionStorage.name
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING'
          value: 'Authorization=AAD'
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
          value: knowledgeStorage.properties.primaryEndpoints.blob
        }
        {
          name: 'AZURE_STORAGE_APPROVED_CONTAINER'
          value: approvedContainer.name
        }
        {
          name: 'KEY_VAULT_URL'
          value: keyVault.properties.vaultUri
        }
      ]
    }
  }
}

// -----------------------------------------------------------------------------
// Serverless frontend. Standard is required when linking a separately managed
// Azure Functions app as the Static Web Apps /api backend.
// -----------------------------------------------------------------------------
resource staticWebApp 'Microsoft.Web/staticSites@2025-03-01' = {
  name: staticWebAppName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
  properties: {
    allowConfigFileUpdates: true
    enterpriseGradeCdnStatus: 'Disabled'
    stagingEnvironmentPolicy: 'Enabled'
  }
}

// -----------------------------------------------------------------------------
// RBAC: Azure AI Search reads approved source documents and can call the Foundry
// embedding deployment for integrated vectorization.
// -----------------------------------------------------------------------------
resource searchStorageReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(knowledgeStorage.id, search.id, storageBlobDataReaderRoleId)
  scope: knowledgeStorage
  properties: {
    principalId: search.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageBlobDataReaderRoleId
  }
}

resource searchFoundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundry.id, search.id, cognitiveServicesOpenAIUserRoleId)
  scope: foundry
  properties: {
    principalId: search.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: cognitiveServicesOpenAIUserRoleId
  }
}

// -----------------------------------------------------------------------------
// RBAC: Function App runtime identity. No Azure service API keys are required.
// -----------------------------------------------------------------------------
resource functionSearchReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, functionApp.id, searchIndexDataReaderRoleId)
  scope: search
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: searchIndexDataReaderRoleId
  }
}

resource functionFoundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundry.id, functionApp.id, cognitiveServicesOpenAIUserRoleId)
  scope: foundry
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: cognitiveServicesOpenAIUserRoleId
  }
}

resource functionKnowledgeStorageReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(knowledgeStorage.id, functionApp.id, storageBlobDataReaderRoleId)
  scope: knowledgeStorage
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageBlobDataReaderRoleId
  }
}

// Storage Blob Data Owner is the documented minimum host-storage role for an
// identity-based AzureWebJobsStorage connection. It also covers the deployment
// container's blob-data requirements for this Function App.
resource functionHostStorageOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(functionStorage.id, functionApp.id, storageBlobDataOwnerRoleId)
  scope: functionStorage
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageBlobDataOwnerRoleId
  }
}

resource functionKeyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, functionApp.id, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: keyVaultSecretsUserRoleId
  }
}

resource functionMonitoringPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appInsights.id, functionApp.id, monitoringMetricsPublisherRoleId)
  scope: appInsights
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: monitoringMetricsPublisherRoleId
  }
}

// -----------------------------------------------------------------------------
// Outputs used by the deployment script, GitHub Actions, and local development.
// -----------------------------------------------------------------------------
output foundryAccountName string = foundry.name
output foundryProjectName string = foundryProject.name
output foundryEndpoint string = foundry.properties.endpoint
output searchServiceName string = search.name
output searchRegion string = searchLocation
output searchEndpoint string = 'https://${search.name}.search.windows.net'
output knowledgeStorageAccountName string = knowledgeStorage.name
output functionStorageAccountName string = functionStorage.name
output approvedContainerName string = approvedContainer.name
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output functionPlanName string = functionPlan.name
output functionAppName string = functionApp.name
output functionAppId string = functionApp.id
output functionAppUrl string = 'https://${functionApp.properties.defaultHostName}'
output staticWebAppName string = staticWebApp.name
output staticWebAppUrl string = 'https://${staticWebApp.properties.defaultHostname}'
output applicationInsightsName string = appInsights.name
output logAnalyticsWorkspaceName string = logAnalytics.name