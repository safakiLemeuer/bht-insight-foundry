[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [string]$ResourceGroupName = "rg-bht-insight-dev-eastus2",

    [string]$Location = "eastus2",

    [string]$ParameterFile = "..\bicep\dev.bicepparam"
)

$ErrorActionPreference = "Stop"

function Assert-Command {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' is not installed or not available in PATH."
    }
}

Assert-Command az

Write-Host "Checking Azure CLI authentication..." -ForegroundColor Cyan
az account show --output none

Write-Host "Selecting Azure subscription $SubscriptionId..." -ForegroundColor Cyan
az account set --subscription $SubscriptionId

Write-Host "Registering required resource providers..." -ForegroundColor Cyan
$providers = @(
    "Microsoft.Authorization",
    "Microsoft.CognitiveServices",
    "Microsoft.Insights",
    "Microsoft.KeyVault",
    "Microsoft.OperationalInsights",
    "Microsoft.Search",
    "Microsoft.Storage",
    "Microsoft.Web"
)

foreach ($provider in $providers) {
    az provider register --namespace $provider --wait
}

Write-Host "Creating or updating resource group $ResourceGroupName..." -ForegroundColor Cyan
az group create `
    --name $ResourceGroupName `
    --location $Location `
    --tags application="BHT Insight Foundry" environment="dev" managedBy="Bicep" phase="1A" `
    --output table

$resolvedParameterFile = Resolve-Path (Join-Path $PSScriptRoot $ParameterFile)
$templateFile = Resolve-Path (Join-Path $PSScriptRoot "..\bicep\main.bicep")

Write-Host "Validating Bicep template..." -ForegroundColor Cyan
az deployment group validate `
    --resource-group $ResourceGroupName `
    --template-file $templateFile `
    --parameters $resolvedParameterFile `
    --output table

Write-Host "Previewing Azure changes..." -ForegroundColor Cyan
az deployment group what-if `
    --resource-group $ResourceGroupName `
    --template-file $templateFile `
    --parameters $resolvedParameterFile

$confirmation = Read-Host "Deploy these resources? Type DEPLOY to continue"
if ($confirmation -cne "DEPLOY") {
    Write-Host "Deployment cancelled. No Azure changes were applied by this script." -ForegroundColor Yellow
    exit 0
}

$deploymentName = "phase1a-$((Get-Date).ToString('yyyyMMdd-HHmmss'))"

Write-Host "Deploying Phase 1A Azure resources..." -ForegroundColor Cyan
az deployment group create `
    --name $deploymentName `
    --resource-group $ResourceGroupName `
    --template-file $templateFile `
    --parameters $resolvedParameterFile `
    --output table

Write-Host "Deployment outputs:" -ForegroundColor Cyan
az deployment group show `
    --name $deploymentName `
    --resource-group $ResourceGroupName `
    --query properties.outputs `
    --output jsonc

Write-Host "Phase 1A infrastructure deployment completed." -ForegroundColor Green
Write-Host "Next: verify model availability and quota, then enable model deployments in dev.bicepparam." -ForegroundColor Yellow
