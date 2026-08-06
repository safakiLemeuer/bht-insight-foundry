using './main.bicep'

// Replace the suffix with 3-8 lowercase letters or numbers unique to your subscription.
param uniqueSuffix = 'bht01'
param location = 'eastus2'
param environment = 'dev'

// Start with infrastructure only. After checking regional quota and available model versions,
// set deployModels to true and supply verified model versions.
param deployModels = false

param chatModelName = 'gpt-4.1-mini'
param chatModelVersion = ''
param chatModelCapacity = 10

param embeddingModelName = 'text-embedding-3-small'
param embeddingModelVersion = '1'
param embeddingModelCapacity = 10

param appServicePlanSku = 'B1'
param searchSku = 'basic'
