# PowerShell script to provision a local k3d cluster on Windows bare-metal
param(
    [string]$ClusterName = "ai-agent-cluster"
)

$ErrorActionPreference = "Stop"

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "  Kubernetes AI Agent - Bare-Metal Windows k3d Setup" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

# 1. Check Docker Desktop
Write-Host "[1/5] Checking Docker..." -ForegroundColor Yellow
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Error "Docker is not installed. Please install Docker Desktop: https://docs.docker.com/desktop/install/windows-install/"
}
try {
    docker info | Out-Null
    Write-Host "Docker is running." -ForegroundColor Green
} catch {
    Write-Error "Docker Desktop is not currently running. Please launch Docker Desktop and retry."
}

# 2. Check / Install k3d
Write-Host "[2/5] Checking k3d CLI..." -ForegroundColor Yellow
if (-not (Get-Command k3d -ErrorAction SilentlyContinue)) {
    Write-Host "k3d not found. Attempting install via winget..." -ForegroundColor Yellow
    winget install Rancher.k3d
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
}
Write-Host "k3d is ready." -ForegroundColor Green

# 3. Check kubectl
Write-Host "[3/5] Checking kubectl..." -ForegroundColor Yellow
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Host "kubectl not found. Attempting install via winget..." -ForegroundColor Yellow
    winget install Kubernetes.kubectl
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
}
Write-Host "kubectl is ready." -ForegroundColor Green

# 4. Create or Start k3d Cluster
Write-Host "[4/5] Provisioning k3d cluster '$ClusterName'..." -ForegroundColor Yellow
$existing = k3d cluster list $ClusterName 2>$null
if ($LASTEXITCODE -eq 0 -and $existing -match $ClusterName) {
    Write-Host "Cluster '$ClusterName' already exists. Starting..." -ForegroundColor Green
    k3d cluster start $ClusterName
} else {
    Write-Host "Creating new k3d cluster '$ClusterName'..." -ForegroundColor Green
    $configPath = Join-Path $PSScriptRoot "..\ai-agent\k8s\k3d-config.yaml"
    if (Test-Path $configPath) {
        k3d cluster create $ClusterName --config $configPath
    } else {
        k3d cluster create $ClusterName `
            --servers 1 `
            --agents 1 `
            -p "8000:8000@loadbalancer" `
            -p "3000:3000@loadbalancer" `
            -p "5432:5432@loadbalancer" `
            -p "80:80@loadbalancer" `
            --wait
    }
}

# 5. Fix Windows 0.0.0.0 socket address resolution
Write-Host "[5/5] Configuring kubeconfig host address..." -ForegroundColor Yellow
$currentServer = (kubectl config view -o jsonpath="{.clusters[?(@.name=='k3d-$ClusterName')].cluster.server}")
if ($currentServer -match "0\.0\.0\.0:(\d+)") {
    $port = $matches[1]
    kubectl config set-cluster "k3d-$ClusterName" --server="https://127.0.0.1:$port" --tls-server-name=0.0.0.0
    Write-Host "Updated kubeconfig to https://127.0.0.1:$port" -ForegroundColor Green
}

# Verify nodes
kubectl wait --for=condition=Ready nodes --all --timeout=90s
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "  Cluster '$ClusterName' is READY!" -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Cyan
kubectl get nodes -o wide
