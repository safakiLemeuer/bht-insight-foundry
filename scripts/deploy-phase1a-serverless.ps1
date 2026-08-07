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

function Test-TransientAzureCliError {
    param([string]$Text)

    return $Text -match "10054|ConnectionResetError|Connection aborted|forcibly closed|temporarily unavailable|timed out|timeout"
}

function Invoke-AzCommandWithRetry {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$MaxAttempts = 4,
        [int]$InitialDelaySeconds = 2
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $output = (& az @Arguments 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            return $output
        }

        $isTransient = Test-TransientAzureCliError -Text $output
        if (-not $isTransient -or $attempt -eq $MaxAttempts) {
            if ($output) {
                Write-Host $output -ForegroundColor Red
            }
            throw "Azure CLI command failed after $attempt attempt(s): az $($Arguments -join ' ')"
        }

        $delay = [int]($InitialDelaySeconds * [math]::Pow(2, $attempt - 1))
        Write-Warning "Transient Azure CLI connection failure on attempt $attempt/$MaxAttempts. Retrying in $delay second(s)..."
        Start-Sleep -Seconds $delay
    }
}

function Invoke-AzJson {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $result = Invoke-AzCommandWithRetry -Arguments ($Arguments + @("--output", "json"))
    if ([string]::IsNullOrWhiteSpace($result)) {
        return $null
    }
    return $result | ConvertFrom-Json
}

function Show-FailedDeploymentOperations {
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$DeploymentName
    )

    Write-Host "" 
    Write-Host "Failed Azure deployment operations:" -ForegroundColor Yellow

    try {
        $failed = & az deployment operation group list `
            --resource-group $ResourceGroupName `
            --name $DeploymentName `
            --query "[?properties.provisioningState=='Failed'].{Resource:properties.targetResource.resourceName,Type:properties.targetResource.resourceType,Status:properties.statusMessage}" `
            --output json 2>$null

        if ($LASTEXITCODE -eq 0 -and $failed) {
            $items = $failed | ConvertFrom-Json
            if ($items.Count -gt 0) {
                $items | Format-List | Out-String | Write-Host
                return
            }
        }
    }
    catch {
        # Preserve the original deployment exception; diagnostics are best effort.
    }

    Write-Host "No failed operation details could be retrieved automatically." -ForegroundColor DarkYellow
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

if ($UniqueSuffix -notmatch '^[a-z0-9]{3,8}$') {
    throw "UniqueSuffix must be 3-8 lowercase letters or numbers. Received '$UniqueSuffix'."
}

Write-Host "Checking required Azure resource providers..." -ForegroundColor Cyan
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
    $state = (Invoke-AzCommandWithRetry -Arguments @(
        "provider", "show",
        "--namespace", $provider,
        "--query", "registrationState",
        "--output", "tsv"
    )).Trim()

    if ($state -eq "Registered") {
        Write-Host "  $provider : Registered" -ForegroundColor Green
        continue
    }

    Write-Host "  $provider : $state -> registering" -ForegroundColor Yellow
    Invoke-AzCommandWithRetry -Arguments @(
        "provider", "register",
        "--namespace", $provider,
        "--output", "none"
    ) | Out-Null

    $registered = $false
    for ($check = 1; $check -le 12; $check++) {
        $state = (Invoke-AzCommandWithRetry -Arguments @(
            "provider", "show",
            "--namespace", $provider,
            "--query", "registrationState",
            "--output", "tsv"
        )).Trim()

        if ($state -eq "Registered") {
            $registered = $true
            Write-Host "  $provider : Registered" -ForegroundColor Green
            break
        }

        Write-Host "  $provider : $state (waiting...)" -ForegroundColor DarkGray
        Start-Sleep -Seconds 5
    }

    if (-not $registered) {
        throw "Resource provider '$provider' did not reach Registered state within the expected time."
    }
}

$existingGroup = (Invoke-AzCommandWithRetry -Arguments @(
    "group", "exists",
    "--name", $ResourceGroup,
    "--output", "tsv"
)).Trim()

if ($existingGroup.ToLowerInvariant() -ne "true") {
    Write-Host "Creating resource group $ResourceGroup in $Location..." -ForegroundColor Cyan
    Invoke-AzCommandWithRetry -Arguments @(
        "group", "create",
        "--name", $ResourceGroup,
        "--location", $Location,
        "--tags",
        "Application=BHT Insight Foundry",
        "Environment=$Environment",
        "Phase=1A",
        "ManagedBy=Bicep",
        "--output", "none"
    ) | Out-Null
}

Write-Host "Compiling Bicep..." -ForegroundColor Cyan
& az bicep build --file .\infra\bicep\main.bicep --stdout | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Bicep compilation failed. Nothing was deployed."
}

$parameters = @(
    "location=$Location",
    "environment=$Environment",
    "uniqueSuffix=$UniqueSuffix",
    "deployModels=false",
    "functionPythonVersion=$PythonVersion"
)

Write-Host "Running Azure what-if for resource location '$Location'..." -ForegroundColor Cyan
$whatIfArgs = @(
    "deployment", "group", "what-if",
    "--resource-group", $ResourceGroup,
    "--template-file", ".\infra\bicep\main.bicep",
    "--parameters"
) + $parameters
$whatIfOutput = Invoke-AzCommandWithRetry -Arguments $whatIfArgs

if ($whatIfOutput) {
    Write-Host $whatIfOutput
}

if (-not $Deploy) {
    Write-Host ""
    Write-Host "Preflight and what-if completed successfully." -ForegroundColor Green
    Write-Host "No infrastructure was deployed." -ForegroundColor Yellow
    Write-Host "Review the what-if output, then deploy with:" -ForegroundColor Cyan
    Write-Host ".\scripts\deploy-phase1a-serverless.ps1 -ResourceGroup '$ResourceGroup' -Location '$Location' -Environment '$Environment' -UniqueSuffix '$UniqueSuffix' -PythonVersion '$PythonVersion' -Deploy"
    exit 0
}

$deploymentName = "phase1a-serverless"
Write-Host "Deploying Phase 1A serverless foundation to '$Location'..." -ForegroundColor Cyan
$deploymentArgs = @(
    "deployment", "group", "create",
    "--resource-group", $ResourceGroup,
    "--name", $deploymentName,
    "--template-file", ".\infra\bicep\main.bicep",
    "--parameters"
) + $parameters + @("--output", "json")

try {
    $deploymentOutput = Invoke-AzCommandWithRetry -Arguments $deploymentArgs
}
catch {
    Show-FailedDeploymentOperations -ResourceGroupName $ResourceGroup -DeploymentName $deploymentName
    throw
}

if ($deploymentOutput) {
    Write-Host $deploymentOutput
}

Write-Host ""
Write-Host "Phase 1A serverless foundation deployed." -ForegroundColor Green
Write-Host "Models are intentionally NOT deployed yet. Model/version/quota will be verified separately." -ForegroundColor Yellow
Write-Host "Next: deploy frontend/API code, then link the standalone Function App to Static Web Apps." -ForegroundColor Cyan
