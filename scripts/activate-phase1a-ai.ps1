[CmdletBinding()]
param(
    [string]$ResourceGroup = "rg-bht-insight-dev",
    [string]$Location = "eastus2",
    [string]$SearchLocation = "centralus",
    [ValidateSet("dev", "test", "prod")]
    [string]$Environment = "dev",
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9]{3,8}$')]
    [string]$UniqueSuffix,
    [string]$ChatModelName = "gpt-4.1-mini",
    [string]$ChatModelVersion = "2025-04-14",
    [string]$EmbeddingModelName = "text-embedding-3-small",
    [string]$EmbeddingModelVersion = "1",
    [int]$ChatModelCapacity = 10,
    [int]$EmbeddingModelCapacity = 10,
    [switch]$DeployModels
)

$ErrorActionPreference = "Stop"

function Invoke-AzJson {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $result = & az @Arguments --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')"
    }

    if ([string]::IsNullOrWhiteSpace(($result | Out-String))) {
        return $null
    }

    return ($result | Out-String) | ConvertFrom-Json
}

function Test-RoleAssignment {
    param(
        [Parameter(Mandatory)][string]$PrincipalId,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$RoleDefinitionId,
        [Parameter(Mandatory)][string]$Label
    )

    $assignments = Invoke-AzJson -Arguments @(
        "role", "assignment", "list",
        "--assignee-object-id", $PrincipalId,
        "--scope", $Scope,
        "--include-inherited",
        "--query", "[?roleDefinitionId=='$RoleDefinitionId']"
    )

    if ($null -eq $assignments -or @($assignments).Count -eq 0) {
        Write-Host "  MISSING: $Label" -ForegroundColor Red
        return $false
    }

    Write-Host "  OK:      $Label" -ForegroundColor Green
    return $true
}

function Get-AccountModelMatch {
    param(
        [Parameter(Mandatory)][object[]]$Models,
        [Parameter(Mandatory)][string]$ModelName,
        [Parameter(Mandatory)][string]$ModelVersion
    )

    return @(
        $Models | Where-Object {
            $topLevelMatch = (
                $_.name -eq $ModelName -and
                $_.version -eq $ModelVersion -and
                ($null -eq $_.format -or $_.format -eq "OpenAI")
            )

            $nestedMatch = (
                $null -ne $_.model -and
                $_.model.name -eq $ModelName -and
                $_.model.version -eq $ModelVersion
            )

            $topLevelMatch -or $nestedMatch
        }
    )
}

function Show-ModelAvailability {
    param(
        [Parameter(Mandatory)][object[]]$Models,
        [Parameter(Mandatory)][string]$ModelName,
        [Parameter(Mandatory)][string]$ModelVersion,
        [Parameter(Mandatory)][string]$LocationName
    )

    $matches = Get-AccountModelMatch -Models $Models -ModelName $ModelName -ModelVersion $ModelVersion

    if ($matches.Count -eq 0) {
        Write-Warning "Model '$ModelName' version '$ModelVersion' was not found in the account model catalog for $LocationName. ARM deployment remains authoritative."
        return $false
    }

    $match = $matches[0]
    $skuNames = @($match.skus | ForEach-Object { $_.name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $lifecycle = if ($match.lifecycleStatus) { $match.lifecycleStatus } else { "Unknown" }
    $format = if ($match.format) { $match.format } else { "Unknown" }

    Write-Host "  OK: $ModelName $ModelVersion" -ForegroundColor Green
    Write-Host "      Format:    $format"
    Write-Host "      Lifecycle: $lifecycle"
    if ($skuNames.Count -gt 0) {
        Write-Host "      SKUs:      $($skuNames -join ', ')"
    }

    return $true
}

if (-not (Test-Path ".\infra\bicep\main.bicep")) {
    throw "Run this script from the repository root."
}

$subscription = Invoke-AzJson -Arguments @("account", "show")
$subscriptionId = $subscription.id

$prefix = "bhtinsight-$Environment-$UniqueSuffix"
$compactPrefix = "bhtinsight$Environment$UniqueSuffix"
$foundryName = "ai-$prefix"
$searchName = "srch-$prefix"
$functionAppName = "func-$prefix"
$knowledgeStorageName = ("st$compactPrefix").Substring(0, [Math]::Min(24, ("st$compactPrefix").Length))
$functionStorageName = ("stfn$compactPrefix").Substring(0, [Math]::Min(24, ("stfn$compactPrefix").Length))
$keyVaultName = ("kv-$prefix").Substring(0, [Math]::Min(24, ("kv-$prefix").Length))
$appInsightsName = "appi-$prefix"

$resourceGroupScope = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup"
$foundryScope = "$resourceGroupScope/providers/Microsoft.CognitiveServices/accounts/$foundryName"
$searchScope = "$resourceGroupScope/providers/Microsoft.Search/searchServices/$searchName"
$knowledgeStorageScope = "$resourceGroupScope/providers/Microsoft.Storage/storageAccounts/$knowledgeStorageName"
$functionStorageScope = "$resourceGroupScope/providers/Microsoft.Storage/storageAccounts/$functionStorageName"
$keyVaultScope = "$resourceGroupScope/providers/Microsoft.KeyVault/vaults/$keyVaultName"
$appInsightsScope = "$resourceGroupScope/providers/Microsoft.Insights/components/$appInsightsName"

$storageBlobDataReaderRoleId = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/roleDefinitions/2a2b9908-6ea1-4ae2-8e65-a410df84e7d1"
$storageBlobDataOwnerRoleId = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/roleDefinitions/b7e6dc6d-f1e8-4753-8033-0f276bb0955b"
$searchIndexDataReaderRoleId = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/roleDefinitions/1407120a-92aa-4202-b7e9-c0e197c71c8f"
$cognitiveServicesOpenAIUserRoleId = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/roleDefinitions/5e0bd9bd-7b93-4f28-af87-19fc36ad61bd"
$keyVaultSecretsUserRoleId = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6"
$monitoringMetricsPublisherRoleId = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/roleDefinitions/3913510d-42f4-4e42-8a64-420c390055eb"

Write-Host "BHT Insight Phase 1A - AI activation" -ForegroundColor Cyan
Write-Host "Subscription: $($subscription.name)" -ForegroundColor Green
Write-Host "Primary:      $Location" -ForegroundColor Green
Write-Host "Search:       $SearchLocation" -ForegroundColor Green
Write-Host "Foundry:      $foundryName" -ForegroundColor Green
Write-Host "Search svc:   $searchName" -ForegroundColor Green

Write-Host "`nVerifying resource identities..." -ForegroundColor Cyan
$functionPrincipalId = (& az functionapp identity show --resource-group $ResourceGroup --name $functionAppName --query principalId --output tsv).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($functionPrincipalId)) {
    throw "Unable to resolve Function App managed identity for '$functionAppName'."
}

$searchPrincipalId = (& az search service show --resource-group $ResourceGroup --name $searchName --query identity.principalId --output tsv).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($searchPrincipalId)) {
    throw "Unable to resolve Azure AI Search managed identity for '$searchName'."
}

Write-Host "  Function identity: $functionPrincipalId"
Write-Host "  Search identity:   $searchPrincipalId"

Write-Host "`nVerifying RBAC assignments..." -ForegroundColor Cyan
$checks = @()
$checks += Test-RoleAssignment -PrincipalId $functionPrincipalId -Scope $searchScope -RoleDefinitionId $searchIndexDataReaderRoleId -Label "Function -> Search Index Data Reader"
$checks += Test-RoleAssignment -PrincipalId $functionPrincipalId -Scope $foundryScope -RoleDefinitionId $cognitiveServicesOpenAIUserRoleId -Label "Function -> Cognitive Services OpenAI User"
$checks += Test-RoleAssignment -PrincipalId $functionPrincipalId -Scope $knowledgeStorageScope -RoleDefinitionId $storageBlobDataReaderRoleId -Label "Function -> Knowledge Storage Blob Data Reader"
$checks += Test-RoleAssignment -PrincipalId $functionPrincipalId -Scope $functionStorageScope -RoleDefinitionId $storageBlobDataOwnerRoleId -Label "Function -> Function Storage Blob Data Owner"
$checks += Test-RoleAssignment -PrincipalId $functionPrincipalId -Scope $keyVaultScope -RoleDefinitionId $keyVaultSecretsUserRoleId -Label "Function -> Key Vault Secrets User"
$checks += Test-RoleAssignment -PrincipalId $functionPrincipalId -Scope $appInsightsScope -RoleDefinitionId $monitoringMetricsPublisherRoleId -Label "Function -> Monitoring Metrics Publisher"
$checks += Test-RoleAssignment -PrincipalId $searchPrincipalId -Scope $knowledgeStorageScope -RoleDefinitionId $storageBlobDataReaderRoleId -Label "Search -> Knowledge Storage Blob Data Reader"
$checks += Test-RoleAssignment -PrincipalId $searchPrincipalId -Scope $foundryScope -RoleDefinitionId $cognitiveServicesOpenAIUserRoleId -Label "Search -> Cognitive Services OpenAI User"

if ($checks -contains $false) {
    throw "One or more required RBAC assignments are missing. Re-run the Phase 1A infrastructure deployment and allow time for RBAC propagation."
}

Write-Host "`nChecking model/version availability from the Foundry account..." -ForegroundColor Cyan
$models = @(Invoke-AzJson -Arguments @(
    "cognitiveservices", "account", "list-models",
    "--resource-group", $ResourceGroup,
    "--name", $foundryName
))

$chatVisible = Show-ModelAvailability -Models $models -ModelName $ChatModelName -ModelVersion $ChatModelVersion -LocationName $Location
$embeddingVisible = Show-ModelAvailability -Models $models -ModelName $EmbeddingModelName -ModelVersion $EmbeddingModelVersion -LocationName $Location

if (-not $DeployModels) {
    Write-Host "`nRBAC checks passed." -ForegroundColor Green
    if ($chatVisible -and $embeddingVisible) {
        Write-Host "Both requested models are present in the account catalog." -ForegroundColor Green
    }
    else {
        Write-Host "One or more model catalog checks were inconclusive; ARM deployment remains authoritative." -ForegroundColor Yellow
    }
    Write-Host "No models were deployed." -ForegroundColor Yellow
    Write-Host "Deploy with:" -ForegroundColor Cyan
    Write-Host ".\scripts\activate-phase1a-ai.ps1 -ResourceGroup '$ResourceGroup' -Location '$Location' -SearchLocation '$SearchLocation' -Environment '$Environment' -UniqueSuffix '$UniqueSuffix' -DeployModels"
    exit 0
}

Write-Host "`nDeploying chat and embedding models..." -ForegroundColor Cyan
$deploymentName = "phase1a-models"
& az deployment group create `
    --resource-group $ResourceGroup `
    --name $deploymentName `
    --template-file .\infra\bicep\main.bicep `
    --parameters `
        location=$Location `
        searchLocation=$SearchLocation `
        environment=$Environment `
        uniqueSuffix=$UniqueSuffix `
        deployModels=true `
        chatModelName=$ChatModelName `
        chatModelVersion=$ChatModelVersion `
        chatModelCapacity=$ChatModelCapacity `
        embeddingModelName=$EmbeddingModelName `
        embeddingModelVersion=$EmbeddingModelVersion `
        embeddingModelCapacity=$EmbeddingModelCapacity `
    --output json

if ($LASTEXITCODE -ne 0) {
    Write-Host "`nFailed model deployment operations:" -ForegroundColor Yellow
    & az deployment operation group list `
        --resource-group $ResourceGroup `
        --name $deploymentName `
        --query "[?properties.provisioningState=='Failed'].{Resource:properties.targetResource.resourceName,Type:properties.targetResource.resourceType,Status:properties.statusMessage}" `
        --output table
    throw "Model deployment failed. ARM has provided the authoritative model/quota/capacity result above."
}

Write-Host "`nVerifying model deployments..." -ForegroundColor Cyan
$deployments = Invoke-AzJson -Arguments @(
    "cognitiveservices", "account", "deployment", "list",
    "--resource-group", $ResourceGroup,
    "--name", $foundryName
)

$deployments | Select-Object name, @{Name='Model';Expression={$_.properties.model.name}}, @{Name='Version';Expression={$_.properties.model.version}}, @{Name='State';Expression={$_.properties.provisioningState}} | Format-Table -AutoSize

$chatDeployment = @($deployments | Where-Object { $_.name -eq "chat-bht-insight" -and $_.properties.provisioningState -eq "Succeeded" })
$embeddingDeployment = @($deployments | Where-Object { $_.name -eq "embed-bht-insight" -and $_.properties.provisioningState -eq "Succeeded" })

if ($chatDeployment.Count -eq 0 -or $embeddingDeployment.Count -eq 0) {
    throw "The expected model deployments are not both in Succeeded state."
}

Write-Host "`nPhase 1A AI models are deployed and RBAC is verified." -ForegroundColor Green
Write-Host "Next: create the Azure AI Search index and deploy the application code." -ForegroundColor Cyan
