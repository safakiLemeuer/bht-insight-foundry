[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "Windows Package Manager (winget) is required."
}

$packages = @(
    "Git.Git",
    "GitHub.cli",
    "Python.Python.3.11",
    "Microsoft.VisualStudioCode",
    "Microsoft.AzureCLI",
    "Microsoft.Bicep",
    "Microsoft.PowerShell"
)

foreach ($package in $packages) {
    Write-Host "Installing or upgrading $package..." -ForegroundColor Cyan
    winget install --id $package --exact --accept-source-agreements --accept-package-agreements
}

Write-Host "Prerequisites installed. Restart PowerShell before running setup-windows.ps1." -ForegroundColor Green
