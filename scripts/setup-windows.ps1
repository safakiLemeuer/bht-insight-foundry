[CmdletBinding()]
param(
    [string]$GitHubOwner = "safakiLemeuer",
    [string]$RepositoryName = "bht-insight-foundry",
    [string]$RepositoryDescription = "Open-source enterprise knowledge assistant built with Azure AI Foundry, Azure OpenAI, Azure AI Search, and Python.",
    [switch]$SkipRepositoryCreation
)

$ErrorActionPreference = "Stop"

function Assert-Command {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' is not installed or is not available in PATH."
    }
}

Write-Host "Validating required tools..." -ForegroundColor Cyan
Assert-Command git
Assert-Command code
Assert-Command python
Assert-Command gh

Write-Host "Checking GitHub authentication..." -ForegroundColor Cyan
gh auth status

Write-Host "Configuring recommended VS Code extensions..." -ForegroundColor Cyan
$extensions = @(
    "ms-python.python",
    "ms-python.vscode-pylance",
    "charliermarsh.ruff",
    "ms-python.black-formatter",
    "github.copilot",
    "github.copilot-chat",
    "github.vscode-pull-request-github",
    "ms-azuretools.vscode-bicep",
    "ms-vscode.azure-account",
    "ms-azuretools.vscode-azureresourcegroups",
    "ms-azuretools.vscode-docker",
    "redhat.vscode-yaml",
    "davidanson.vscode-markdownlint",
    "editorconfig.editorconfig",
    "eamodio.gitlens"
)

foreach ($extension in $extensions) {
    code --install-extension $extension --force
}

if (-not (Test-Path ".git")) {
    Write-Host "Initializing Git repository..." -ForegroundColor Cyan
    git init -b main
}

Write-Host "Creating Python virtual environment..." -ForegroundColor Cyan
python -m venv .venv
& ".\.venv\Scripts\python.exe" -m pip install --upgrade pip
& ".\.venv\Scripts\python.exe" -m pip install -e ".[dev]"
& ".\.venv\Scripts\python.exe" -m pre_commit install

Write-Host "Running repository quality checks..." -ForegroundColor Cyan
& ".\.venv\Scripts\python.exe" -m ruff check .
& ".\.venv\Scripts\python.exe" -m ruff format --check .
& ".\.venv\Scripts\python.exe" -m pyright
& ".\.venv\Scripts\python.exe" -m pytest
& ".\.venv\Scripts\python.exe" -m bandit -r src
& ".\.venv\Scripts\python.exe" -m pip_audit

git add .
git commit -m "chore: establish secure repository foundation"

if (-not $SkipRepositoryCreation) {
    $fullName = "$GitHubOwner/$RepositoryName"
    Write-Host "Creating public GitHub repository $fullName..." -ForegroundColor Cyan
    gh repo create $fullName `
        --public `
        --description $RepositoryDescription `
        --source . `
        --remote origin `
        --push

    Write-Host "Opening repository in browser..." -ForegroundColor Cyan
    gh repo view $fullName --web
}

Write-Host ""
Write-Host "Repository foundation completed." -ForegroundColor Green
Write-Host "Next: enable GitHub rulesets, secret scanning, push protection, and private vulnerability reporting in repository settings." -ForegroundColor Yellow
