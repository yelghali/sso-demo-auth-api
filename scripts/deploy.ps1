<#
.SYNOPSIS
    Deploy the SSO Demo infrastructure and applications.
.DESCRIPTION
    This script runs Terraform to create all Azure resources, builds the API
    container image, and pushes it to ACR. Run from the repo root.
#>
param(
    [switch]$SkipTerraform,
    [switch]$DestroyAll
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot  = $PSScriptRoot | Split-Path
$tfDir     = Join-Path $repoRoot "terraform"
$apisDir   = Join-Path $repoRoot "apis"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  SSO Demo - Deployment Script" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# ── Preflight checks ───────────────────────────────────────────
foreach ($cmd in @("az", "terraform", "kubectl")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Error "$cmd is required but not found in PATH."
    }
}

# Verify Azure login
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) { Write-Error "Not logged in to Azure. Run: az login" }
Write-Host "Azure subscription: $($account.name) ($($account.id))" -ForegroundColor Green

# ── Terraform ──────────────────────────────────────────────────
Push-Location $tfDir
try {
    if ($DestroyAll) {
        Write-Host "`n--- Destroying all resources ---`n" -ForegroundColor Red
        terraform destroy -auto-approve
        Pop-Location
        return
    }

    if (-not $SkipTerraform) {
        Write-Host "`n--- Terraform Init ---`n" -ForegroundColor Yellow
        terraform init -upgrade

        Write-Host "`n--- Terraform Plan ---`n" -ForegroundColor Yellow
        terraform plan -out=tfplan

        Write-Host "`n--- Terraform Apply ---`n" -ForegroundColor Yellow
        terraform apply tfplan
    }

    # ── Read outputs ───────────────────────────────────────────
    $outputs = terraform output -json | ConvertFrom-Json
    $rg       = $outputs.resource_group.value
    $acr      = $outputs.acr_login_server.value
    $acrName  = ($acr -split "\.")[0]
    $aks1     = $outputs.aks1_name.value
    $aks2     = $outputs.aks2_name.value
    $appUrl   = $outputs.app_url.value

} finally {
    Pop-Location
}

# ── Build & push API image to ACR ─────────────────────────────
Write-Host "`n--- Building API container image ---`n" -ForegroundColor Yellow
az acr build --registry $acrName --image demo-api:latest $apisDir

# ── Restart deployments to pick up new image ───────────────────
Write-Host "`n--- Restarting pods on Cluster 1 (AGC) ---" -ForegroundColor Yellow
az aks get-credentials --resource-group $rg --name $aks1 --overwrite-existing --admin
kubectl rollout restart deployment -n demo-apis

Write-Host "`n--- Restarting pods on Cluster 2 (Traefik) ---" -ForegroundColor Yellow
az aks get-credentials --resource-group $rg --name $aks2 --overwrite-existing --admin
kubectl rollout restart deployment -n demo-apis

# ── Done ───────────────────────────────────────────────────────
Write-Host "`n========================================" -ForegroundColor Green
Write-Host "  Deployment complete!" -ForegroundColor Green
Write-Host "  App URL: $appUrl" -ForegroundColor Green
Write-Host "  (Accept the self-signed certificate warning)" -ForegroundColor Yellow
Write-Host "========================================`n" -ForegroundColor Green
