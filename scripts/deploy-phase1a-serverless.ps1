[CmdletBinding()]
param(
    [string]$ResourceGroup = "rg-bht-insight-dev",
    [string]$Location = "eastus2",
    [ValidateSet("dev", "test", "prod")]
    [string]$Environment = "dev",
    [string]$UniqueSuffix = "",
    [string]$PythonVersion = "3.12",
    [switch]$Deploy
)

$ErrorActionPreference = "Stop"

function Assert-Command {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' is not installed or is not available in PATH."
    }
}

function Invoke-AzJson {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $result = & az @Arguments --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')"
    }
    return $result | ConvertFrom-Json
}

Assert-Command az

if (-not (Test-Path ".\infra\bicep\main.bicep")) {
    throw "Run this script from the repository root. Expected .\infra\bicep\main.bicep."
}

Write-Host "BHT Insight Phase 1A - serverless infrastructure preflight" -ForegroundColor Cyan
Write-Host "No B1 App Service plan, VM, Docker, AKS, or Container Apps will be deployed." -ForegroundColor DarkGray

$account = Invoke-AzJson -Arguments @("account", "show")
Write-Host "Subscription: $($account.name)" -ForegroundColor Green
Write-Host "Tenant:       $($account.tenantId)" -ForegroundColor Green

Write-Host "Checking Flex Consumption regional availability..." -ForegroundColor Cyan
$flexLocations = Invoke-AzJson -Arguments @("functionapp", "list-flexconsumption-locations")
$locationSupported = $flexLocations | Where-Object { $_.name -eq $Location }
if (-not $locationSupported) {
    Write-Host "Flex Consumption is not available in '$Location'." -ForegroundColor Red
    Write-Host "Supported regions:" -ForegroundColor Yellow
    $flexLocations | Sort-Object name | Select-Object -ExpandProperty name
    throw "Choose a supported region and rerun the script. Do not request B1/Bsv2 quota for this architecture."
}

Write-Host "Checking Python $PythonVersion availability in $Location..." -ForegroundColor Cyan
$runtimes = Invoke-AzJson -Arguments @(
    "functionapp", "list-flexconsumption-runtimes",
    "--location", $Location,
    "--runtime", "python"
)

$runtimeSupported = $runtimes | Where-Object { $_.version -eq $PythonVersion }
if (-not $runtimeSupported) {
    Write-Host "Python $PythonVersion is not available for Flex Consumption in '$Location'." -ForegroundColor Red
    Write-Host "Supported Python versions:" -ForegroundColor Yellow
    $runtimes | Select-Object -ExpandProperty version
    throw "Select a supported Python runtime version and rerun."
}

if ([string]::IsNullOrWhiteSpace($UniqueSuffix)) {
    $UniqueSuffix = [System.Guid]::NewGuid().ToString("N").Substring(0, 5)
    Write-Host "Generated unique suffix: $UniqueSuffix" -ForegroundColor Yellow
}

Write-Host "Registering required Azure resource providers..." -ForegroundColor Cyan
$providers = @(
    "Microsoft.CognitiveServices",
    "Microsoft.Search",
    "Microsoft.Storage",
    "Microsoft.Web",
    "Microsoft.KeyVault",
    "Microsoft.Insights",
    "Microsoft.OperationalInsights",
    "Microsoft.Authorization"
)

foreach ($provider in $providers) {
    & az provider register --namespace $provider --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to register resource provider '$provider'."
    }
}

$existingGroup = & az group exists --name $ResourceGroup
if ($LASTEXITCODE -ne 0) {
    throw "Unable to check resource group '$ResourceGroup'."
}

if ($existingGroup.Trim().ToLowerInvariant() -ne "true") {
    Write-Host "Creating resource group $ResourceGroup in $Location..." -ForegroundColor Cyan
    & az group create `
        --name $ResourceGroup `
        --location $Location `
        --tags Application="BHT Insight Foundry" Environment=$Environment Phase="1A" ManagedBy="Bicep" `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Resource group creation failed."
    }
}

Write-Host "Compiling Bicep..." -ForegroundColor Cyan
& az bicep build --file .\infra\bicep\main.bicep --stdout | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Bicep compilation failed. Nothing was deployed."
}

$parameters = @(
    "environment=$Environment",
    "uniqueSuffix=$UniqueSuffix",
    "deployModels=false",
    "functionPythonVersion=$PythonVersion"
)

Write-Host "Running Azure what-if..." -ForegroundColor Cyan
& az deployment group what-if `
    --resource-group $ResourceGroup `
    --template-file .\infra\bicep\main.bicep `
    --parameters @parameters
if ($LASTEXITCODE -ne 0) {
    throw "Azure what-if failed. Nothing was deployed."
}

if (-not $Deploy) {
    Write-Host "" 
    Write-Host "Preflight and what-if completed successfully." -ForegroundColor Green
    Write-Host "No infrastructure was deployed." -ForegroundColor Yellow
    Write-Host "Review the what-if output, then deploy with:" -ForegroundColor Cyan
    Write-Host ".\scripts\deploy-phase1a-serverless.ps1 -ResourceGroup '$ResourceGroup' -Location '$Location' -Environment '$Environment' -UniqueSuffix '$UniqueSuffix' -PythonVersion '$PythonVersion' -Deploy"
    exit 0
}

Write-Host "Deploying Phase 1A serverless foundation..." -ForegroundColor Cyan
& az deployment group create `
    --resource-group $ResourceGroup `
    --name "phase1a-serverless" `
    --template-file .\infra\bicep\main.bicep `
    --parameters @parameters `
    --output json
if ($LASTEXITCODE -ne 0) {
    throw "Infrastructure deployment failed. Inspect the Azure deployment operation before retrying."
}

Write-Host "" 
Write-Host "Phase 1A serverless foundation deployed." -ForegroundColor Green
Write-Host "Models are intentionally NOT deployed yet. Model/version/quota will be verified separately." -ForegroundColor Yellow
Write-Host "Next: deploy frontend/API code, then link the standalone Function App to Static Web Apps." -ForegroundColor Cyan
