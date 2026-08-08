[CmdletBinding()]
param(
    [string]$ResourceGroup = "rg-bht-insight-dev",
    [ValidateSet("dev", "test", "prod")]
    [string]$Environment = "dev",
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9]{3,8}$')]
    [string]$UniqueSuffix,
    [string]$IndexName = "bht-insight-chunks"
)

$ErrorActionPreference = "Stop"

function Assert-Command {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' is not installed or not available in PATH."
    }
}

Assert-Command az

$prefix = "bhtinsight-$Environment-$UniqueSuffix"
$functionAppName = "func-$prefix"
$foundryName = "ai-$prefix"
$searchName = "srch-$prefix"

Write-Host "BHT Insight Phase 1A - Function API deployment" -ForegroundColor Cyan
Write-Host "Function: $functionAppName" -ForegroundColor Green
Write-Host "Foundry:  $foundryName" -ForegroundColor Green
Write-Host "Search:   $searchName / $IndexName" -ForegroundColor Green

$function = (& az functionapp show `
    --resource-group $ResourceGroup `
    --name $functionAppName `
    --output json | Out-String) | ConvertFrom-Json

if ($LASTEXITCODE -ne 0 -or $null -eq $function) {
    throw "Function App '$functionAppName' was not found."
}

$search = (& az search service show `
    --resource-group $ResourceGroup `
    --name $searchName `
    --output json | Out-String) | ConvertFrom-Json

if ($LASTEXITCODE -ne 0 -or $null -eq $search) {
    throw "Search service '$searchName' was not found."
}

$deployments = (& az cognitiveservices account deployment list `
    --resource-group $ResourceGroup `
    --name $foundryName `
    --output json | Out-String) | ConvertFrom-Json

if ($LASTEXITCODE -ne 0) {
    throw "Unable to verify Foundry model deployments."
}

$chat = @($deployments | Where-Object { $_.name -eq "chat-bht-insight" -and $_.properties.provisioningState -eq "Succeeded" })
$embedding = @($deployments | Where-Object { $_.name -eq "embed-bht-insight" -and $_.properties.provisioningState -eq "Succeeded" })
if ($chat.Count -ne 1 -or $embedding.Count -ne 1) {
    throw "Expected chat and embedding deployments are not both in Succeeded state."
}

$openAiEndpoint = "https://$foundryName.openai.azure.com"
$searchEndpoint = "https://$searchName.search.windows.net"

Write-Host "Updating non-secret application settings..." -ForegroundColor Cyan
& az functionapp config appsettings set `
    --resource-group $ResourceGroup `
    --name $functionAppName `
    --settings `
        AZURE_OPENAI_ENDPOINT=$openAiEndpoint `
        AZURE_OPENAI_API_VERSION=2024-10-21 `
        AZURE_OPENAI_CHAT_DEPLOYMENT=chat-bht-insight `
        AZURE_OPENAI_EMBEDDING_DEPLOYMENT=embed-bht-insight `
        AZURE_SEARCH_ENDPOINT=$searchEndpoint `
        AZURE_SEARCH_INDEX=$IndexName `
        RAG_RETRIEVAL_TOP_K=5 `
    --output none

if ($LASTEXITCODE -ne 0) {
    throw "Unable to update Function App application settings."
}

$requiredPaths = @(
    ".\function_app.py",
    ".\host.json",
    ".\requirements.txt",
    ".\src"
)
foreach ($path in $requiredPaths) {
    if (-not (Test-Path $path)) {
        throw "Required deployment path '$path' is missing. Run this script from the repository root."
    }
}

$buildRoot = Join-Path $PWD ".build\phase1a-function"
$zipPath = Join-Path $PWD ".build\phase1a-function.zip"

if (Test-Path $buildRoot) {
    Remove-Item $buildRoot -Recurse -Force
}
if (Test-Path $zipPath) {
    Remove-Item $zipPath -Force
}

New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
Copy-Item ".\function_app.py" $buildRoot
Copy-Item ".\host.json" $buildRoot
Copy-Item ".\requirements.txt" $buildRoot
Copy-Item ".\src" $buildRoot -Recurse

Write-Host "Creating deployment package..." -ForegroundColor Cyan
Compress-Archive -Path "$buildRoot\*" -DestinationPath $zipPath -CompressionLevel Optimal

Write-Host "Deploying to Flex Consumption with remote Python build..." -ForegroundColor Cyan
& az functionapp deployment source config-zip `
    --resource-group $ResourceGroup `
    --name $functionAppName `
    --src $zipPath `
    --build-remote true `
    --timeout 1200 `
    --output none

if ($LASTEXITCODE -ne 0) {
    throw "Function App package deployment failed."
}

$hostName = (& az functionapp show `
    --resource-group $ResourceGroup `
    --name $functionAppName `
    --query defaultHostName `
    --output tsv).Trim()

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($hostName)) {
    throw "Deployment succeeded but the Function App hostname could not be resolved."
}

$healthUri = "https://$hostName/health"
Write-Host "Waiting for API health endpoint..." -ForegroundColor Cyan
$healthy = $false
for ($attempt = 1; $attempt -le 12; $attempt++) {
    try {
        $response = Invoke-RestMethod -Method Get -Uri $healthUri -TimeoutSec 20
        if ($response.status -eq "healthy") {
            $healthy = $true
            break
        }
    }
    catch {
        Start-Sleep -Seconds 10
    }
}

if (-not $healthy) {
    throw "Function package deployed, but '$healthUri' did not become healthy within the validation window."
}

Write-Host "" 
Write-Host "Phase 1A Function API deployed and healthy." -ForegroundColor Green
Write-Host "  Health: $healthUri" -ForegroundColor DarkGray
Write-Host "  Ask:    https://$hostName/ask" -ForegroundColor DarkGray
Write-Host "Next: ingest an approved document into '$IndexName', then run the first grounded query." -ForegroundColor Cyan
