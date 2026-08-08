[CmdletBinding()]
param(
    [string]$ResourceGroup = "rg-bht-insight-dev",
    [ValidateSet("dev", "test", "prod")]
    [string]$Environment = "dev",
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9]{3,8}$')]
    [string]$UniqueSuffix,
    [string]$IndexName = "bht-insight-chunks",
    [string]$SchemaPath = ".\infra\search\bht-insight-chunks.json",
    [string]$ApiVersion = "2025-09-01"
)

$ErrorActionPreference = "Stop"

function Assert-Command {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' is not installed or not available in PATH."
    }
}

function Invoke-SearchRest {
    param(
        [Parameter(Mandatory)][ValidateSet("GET", "PUT")][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Token,
        [string]$Body
    )

    $headers = @{
        Authorization = "Bearer $Token"
        Accept = "application/json"
    }

    try {
        if ($Method -eq "PUT") {
            return Invoke-RestMethod `
                -Method Put `
                -Uri $Uri `
                -Headers $headers `
                -ContentType "application/json" `
                -Body $Body
        }

        return Invoke-RestMethod -Method Get -Uri $Uri -Headers $headers
    }
    catch {
        $response = $_.Exception.Response
        if ($null -ne $response -and [int]$response.StatusCode -eq 403) {
            throw @"
Azure AI Search rejected the data-plane request with HTTP 403.
The signed-in identity needs the 'Search Service Contributor' role on the Search service to create or update index definitions.

Example:
az role assignment create --assignee <YOUR-OBJECT-ID> --role 'Search Service Contributor' --scope <SEARCH-SERVICE-RESOURCE-ID>

After assigning the role, allow several minutes for RBAC propagation and rerun this script.
"@
        }
        throw
    }
}

Assert-Command az

if (-not (Test-Path $SchemaPath)) {
    throw "Search schema not found at '$SchemaPath'. Run this script from the repository root."
}

$subscription = (& az account show --output json | Out-String) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $null -eq $subscription) {
    throw "Unable to read the active Azure subscription. Run 'az login' first."
}

$prefix = "bhtinsight-$Environment-$UniqueSuffix"
$searchName = "srch-$prefix"

Write-Host "BHT Insight Phase 1A - Search index setup" -ForegroundColor Cyan
Write-Host "Subscription: $($subscription.name)" -ForegroundColor Green
Write-Host "Search svc:   $searchName" -ForegroundColor Green
Write-Host "Index:        $IndexName" -ForegroundColor Green

$search = (& az search service show `
    --resource-group $ResourceGroup `
    --name $searchName `
    --output json | Out-String) | ConvertFrom-Json

if ($LASTEXITCODE -ne 0 -or $null -eq $search) {
    throw "Azure AI Search service '$searchName' was not found in resource group '$ResourceGroup'."
}

if (-not $search.disableLocalAuth) {
    throw "Search service '$searchName' is not configured for Entra-only authentication. Refusing to continue with a keyless setup assumption."
}

Write-Host "Search location: $($search.location)" -ForegroundColor Green
Write-Host "Local auth:      disabled" -ForegroundColor Green

$token = (& az account get-access-token `
    --scope "https://search.azure.com/.default" `
    --query accessToken `
    --output tsv).Trim()

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
    throw "Unable to acquire an Azure AI Search data-plane token."
}

$schema = Get-Content $SchemaPath -Raw | ConvertFrom-Json
$schema.name = $IndexName
$body = $schema | ConvertTo-Json -Depth 30 -Compress

$endpoint = "https://$searchName.search.windows.net"
$indexUri = "$endpoint/indexes('$IndexName')?api-version=$ApiVersion"

Write-Host "Creating or updating index using Microsoft Entra authentication..." -ForegroundColor Cyan
$result = Invoke-SearchRest -Method PUT -Uri $indexUri -Token $token -Body $body

if ($null -eq $result -or $result.name -ne $IndexName) {
    throw "Azure AI Search did not return the expected index definition after create/update."
}

Write-Host "Index create/update succeeded." -ForegroundColor Green

Write-Host "Verifying deployed index definition..." -ForegroundColor Cyan
$deployed = Invoke-SearchRest -Method GET -Uri $indexUri -Token $token

$vectorField = @($deployed.fields | Where-Object { $_.name -eq "content_vector" })
if ($vectorField.Count -ne 1) {
    throw "The deployed index is missing the expected 'content_vector' field."
}

if ([int]$vectorField[0].dimensions -ne 1536) {
    throw "Unexpected vector dimensions. Expected 1536, received '$($vectorField[0].dimensions)'."
}

if ($vectorField[0].vectorSearchProfile -ne "bht-vector-profile") {
    throw "The deployed vector field is not using the expected vector search profile."
}

Write-Host "" 
Write-Host "Phase 1A Search index is ready." -ForegroundColor Green
Write-Host "  Endpoint:   $endpoint" -ForegroundColor DarkGray
Write-Host "  Index:      $IndexName" -ForegroundColor DarkGray
Write-Host "  Vector:     content_vector (1536 dimensions, cosine/HNSW)" -ForegroundColor DarkGray
Write-Host "  Semantic:   bht-semantic" -ForegroundColor DarkGray
Write-Host "Next: deploy the Function API and ingest the first approved document." -ForegroundColor Cyan
