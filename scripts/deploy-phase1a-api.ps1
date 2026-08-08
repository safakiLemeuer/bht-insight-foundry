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

function Invoke-AzWithRetry {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$MaxAttempts = 6,
        [int]$InitialDelaySeconds = 5
    )

    $delay = $InitialDelaySeconds

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $stdoutFile = [System.IO.Path]::GetTempFileName()
        $stderrFile = [System.IO.Path]::GetTempFileName()

        try {
            & az @Arguments 1>$stdoutFile 2>$stderrFile
            $exitCode = $LASTEXITCODE
            $stdout = Get-Content $stdoutFile -Raw -ErrorAction SilentlyContinue
            $stderr = Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue

            if ($exitCode -eq 0) {
                return [pscustomobject]@{
                    ExitCode = 0
                    StdOut = $stdout
                    StdErr = $stderr
                }
            }

            $combined = "$stdout`n$stderr"
            $isTransient = (
                $combined -match '10054' -or
                $combined -match 'ConnectionResetError' -or
                $combined -match 'Connection aborted' -or
                $combined -match 'forcibly closed by the remote host' -or
                $combined -match 'RemoteDisconnected' -or
                $combined -match 'temporarily unavailable' -or
                $combined -match 'timed out' -or
                $combined -match 'TimeoutError'
            )

            if (-not $isTransient -or $attempt -eq $MaxAttempts) {
                return [pscustomobject]@{
                    ExitCode = $exitCode
                    StdOut = $stdout
                    StdErr = $stderr
                }
            }

            Write-Warning "Transient Azure CLI/network failure on attempt $attempt/$MaxAttempts. Retrying in $delay seconds..."
            Start-Sleep -Seconds $delay
            $delay = [Math]::Min($delay * 2, 30)
        }
        finally {
            Remove-Item $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Convert-AzJsonResult {
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][string]$OperationLabel
    )

    if ($Result.ExitCode -ne 0) {
        $details = ($Result.StdErr | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($details)) {
            $details = ($Result.StdOut | Out-String).Trim()
        }
        throw "$OperationLabel failed.`n$details"
    }

    if ([string]::IsNullOrWhiteSpace($Result.StdOut)) {
        return $null
    }

    return $Result.StdOut | ConvertFrom-Json
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

Write-Host "Reading active subscription..." -ForegroundColor Cyan
$accountResult = Invoke-AzWithRetry -Arguments @("account", "show", "--output", "json")
$account = Convert-AzJsonResult -Result $accountResult -OperationLabel "Azure subscription lookup"
if ($null -eq $account -or [string]::IsNullOrWhiteSpace($account.id)) {
    throw "Unable to resolve the active Azure subscription."
}
$subscriptionId = $account.id

# Use generic ARM REST for Function App lookup. This avoids the Azure CLI App Service
# custom command path that repeatedly fails TLS handshakes on some Windows installations.
$functionResourceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$functionAppName"
$functionApiVersion = "2023-12-01"
$functionArmUrl = "https://management.azure.com${functionResourceId}?api-version=${functionApiVersion}"

Write-Host "Verifying Function App through ARM REST..." -ForegroundColor Cyan
$functionResult = Invoke-AzWithRetry -Arguments @(
    "rest",
    "--method", "get",
    "--url", $functionArmUrl,
    "--resource", "https://management.azure.com/",
    "--output", "json"
)

if ($functionResult.ExitCode -ne 0) {
    $details = "$($functionResult.StdOut)`n$($functionResult.StdErr)"
    if ($details -match 'ResourceNotFound|NotFound|could not be found|404') {
        throw "Function App '$functionAppName' was not found in resource group '$ResourceGroup'."
    }
    throw "Unable to verify Function App '$functionAppName' through ARM REST after retries.`n$details"
}

$function = Convert-AzJsonResult -Result $functionResult -OperationLabel "Function App ARM lookup"
if ($null -eq $function) {
    throw "Function App ARM lookup returned no data for '$functionAppName'."
}

Write-Host "  Function state: $($function.properties.state)" -ForegroundColor Green

Write-Host "Verifying Azure AI Search service..." -ForegroundColor Cyan
$searchResult = Invoke-AzWithRetry -Arguments @(
    "search", "service", "show",
    "--resource-group", $ResourceGroup,
    "--name", $searchName,
    "--output", "json"
)
$search = Convert-AzJsonResult -Result $searchResult -OperationLabel "Search service lookup"
if ($null -eq $search) {
    throw "Search service lookup returned no data for '$searchName'."
}

Write-Host "Verifying Foundry model deployments..." -ForegroundColor Cyan
$deploymentsResult = Invoke-AzWithRetry -Arguments @(
    "cognitiveservices", "account", "deployment", "list",
    "--resource-group", $ResourceGroup,
    "--name", $foundryName,
    "--output", "json"
)
$deployments = Convert-AzJsonResult -Result $deploymentsResult -OperationLabel "Foundry deployment lookup"

$chat = @($deployments | Where-Object { $_.name -eq "chat-bht-insight" -and $_.properties.provisioningState -eq "Succeeded" })
$embedding = @($deployments | Where-Object { $_.name -eq "embed-bht-insight" -and $_.properties.provisioningState -eq "Succeeded" })
if ($chat.Count -ne 1 -or $embedding.Count -ne 1) {
    throw "Expected chat and embedding deployments are not both in Succeeded state."
}

$openAiEndpoint = "https://$foundryName.openai.azure.com"
$searchEndpoint = "https://$searchName.search.windows.net"

Write-Host "Updating non-secret application settings..." -ForegroundColor Cyan
$appSettingsResult = Invoke-AzWithRetry -Arguments @(
    "functionapp", "config", "appsettings", "set",
    "--resource-group", $ResourceGroup,
    "--name", $functionAppName,
    "--settings",
    "AZURE_OPENAI_ENDPOINT=$openAiEndpoint",
    "AZURE_OPENAI_API_VERSION=2024-10-21",
    "AZURE_OPENAI_CHAT_DEPLOYMENT=chat-bht-insight",
    "AZURE_OPENAI_EMBEDDING_DEPLOYMENT=embed-bht-insight",
    "AZURE_SEARCH_ENDPOINT=$searchEndpoint",
    "AZURE_SEARCH_INDEX=$IndexName",
    "RAG_RETRIEVAL_TOP_K=5",
    "--output", "none"
)
if ($appSettingsResult.ExitCode -ne 0) {
    throw "Unable to update Function App application settings after retries.`n$($appSettingsResult.StdErr)"
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
$deployResult = Invoke-AzWithRetry -Arguments @(
    "functionapp", "deployment", "source", "config-zip",
    "--resource-group", $ResourceGroup,
    "--name", $functionAppName,
    "--src", $zipPath,
    "--build-remote", "true",
    "--timeout", "1200",
    "--output", "none"
) -MaxAttempts 4 -InitialDelaySeconds 10

if ($deployResult.ExitCode -ne 0) {
    throw "Function App package deployment failed after retries.`n$($deployResult.StdErr)"
}

# Reuse the ARM resource already read above for the hostname. If the platform did not
# return a hostname in that response, refresh it through ARM REST rather than functionapp show.
$hostName = $function.properties.defaultHostName
if ([string]::IsNullOrWhiteSpace($hostName)) {
    $hostResult = Invoke-AzWithRetry -Arguments @(
        "rest",
        "--method", "get",
        "--url", $functionArmUrl,
        "--resource", "https://management.azure.com/",
        "--query", "properties.defaultHostName",
        "--output", "tsv"
    )
    if ($hostResult.ExitCode -ne 0) {
        throw "Deployment succeeded, but the Function App hostname ARM lookup failed after retries.`n$($hostResult.StdErr)"
    }
    $hostName = ($hostResult.StdOut | Out-String).Trim()
}

if ([string]::IsNullOrWhiteSpace($hostName)) {
    throw "Deployment succeeded but the Function App hostname could not be resolved."
}

$healthUri = "https://$hostName/health"
Write-Host "Waiting for API health endpoint..." -ForegroundColor Cyan
$healthy = $false
for ($attempt = 1; $attempt -le 18; $attempt++) {
    try {
        $response = Invoke-RestMethod -Method Get -Uri $healthUri -TimeoutSec 20
        if ($response.status -eq "healthy") {
            $healthy = $true
            break
        }
    }
    catch {
        Write-Host "  Health check $attempt/18 not ready; retrying..." -ForegroundColor DarkGray
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
