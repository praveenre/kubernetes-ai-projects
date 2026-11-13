# Local Pipeline Test Runner (Simulating Jenkins / CI Stages locally on Windows)
param(
    [string]$ImageTag = "local-test-$(Get-Random -Minimum 1000 -Maximum 9999)"
)

$ErrorActionPreference = "Stop"

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "  Kubernetes AI Agent - Local CI/CD Pipeline Execution" -ForegroundColor Cyan
Write-Host "  (Simulating Jenkins Stages against Local Infrastructure)" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

# -------------------------------------------------------------
# Stage 1: Lint & Manifest Validation
# -------------------------------------------------------------
Write-Host "`n>>> [Stage 1/6] Lint & Manifest Validation..." -ForegroundColor Yellow
$pyFiles = @(
    "ai-agent/agent-backend/app/main.py",
    "ai-agent/agent-backend/app/infra/llm.py",
    "ai-agent/agent-backend/app/agent/graph.py",
    "ai-agent/agent-backend/app/agent/nodes.py"
)
foreach ($file in $pyFiles) {
    if (Test-Path $file) {
        python -m py_compile $file
        Write-Host "  [✓] Python syntax compiled: $file" -ForegroundColor Green
    }
}

Write-Host "  Validating Kustomize manifests..." -ForegroundColor Cyan
kubectl kustomize ai-agent/k8s/ | Out-Null
Write-Host "  [✓] Kustomize manifests validated." -ForegroundColor Green

# -------------------------------------------------------------
# Stage 2: Infrastructure Provisioning / Cluster Check
# -------------------------------------------------------------
Write-Host "`n>>> [Stage 2/6] Infra Provisioning (k3d Cluster Check & Setup)..." -ForegroundColor Yellow
& "$PSScriptRoot\setup-k3d.ps1"

$activeCluster = "ai-agent-cluster"
$clusterFile = Join-Path $PSScriptRoot "..\.k3d-active-cluster"
if (Test-Path $clusterFile) {
    $activeCluster = (Get-Content $clusterFile -Raw).Trim()
}
Write-Host "  Active Target Cluster: $activeCluster" -ForegroundColor Green

# -------------------------------------------------------------
# Stage 3: Build & Import Images into k3d
# -------------------------------------------------------------
Write-Host "`n>>> [Stage 3/6] Building & Importing Images into k3d..." -ForegroundColor Yellow
$backendImg = "devopscube/ai-agent-backend:$ImageTag"
$frontendImg = "devopscube/ai-agent-frontend:$ImageTag"

Write-Host "  Building Backend Image: $backendImg..." -ForegroundColor Cyan
docker build -t $backendImg ai-agent/agent-backend

Write-Host "  Building Frontend Image: $frontendImg..." -ForegroundColor Cyan
docker build -t $frontendImg ai-agent/agent-interface

Write-Host "  Importing Images into k3d Cluster '$activeCluster'..." -ForegroundColor Cyan
k3d image import $backendImg $frontendImg -c $activeCluster
Write-Host "  [✓] Images imported into k3d cluster." -ForegroundColor Green

# -------------------------------------------------------------
# Stage 4: Deploy Database Infrastructure (Postgres)
# -------------------------------------------------------------
Write-Host "`n>>> [Stage 4/6] Deploying Postgres Database & Secrets..." -ForegroundColor Yellow
kubectl apply -f ai-agent/k8s/manifests/namespace.yaml
kubectl apply -f ai-agent/k8s/manifests/configmap.yaml

# Check for existing MESH_API_KEY from environment or local .env
$meshKey = $env:MESH_API_KEY
if (-not $meshKey -and (Test-Path "ai-agent/agent-backend/.env")) {
    $envContent = Get-Content "ai-agent/agent-backend/.env"
    foreach ($line in $envContent) {
        if ($line -match "^\s*MESH_API_KEY=(.*)$") {
            $meshKey = $matches[1].Trim(" '`"")
            break
        }
    }
}
if (-not $meshKey) {
    $meshKey = "mock-ci-key-for-healthcheck"
}

kubectl create secret generic ai-agent-secrets -n ai-agent `
  --from-literal=DATABASE_PASSWORD=changeme `
  --from-literal=MESH_API_KEY="$meshKey" `
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic ai-agent-postgres-secrets -n ai-agent `
  --from-literal=POSTGRES_PASSWORD=changeme `
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f ai-agent/k8s/manifests/postgres.yaml

Write-Host "  Waiting for Postgres StatefulSet rollout..." -ForegroundColor Cyan
kubectl rollout status statefulset/ai-agent-postgres -n ai-agent --timeout=120s
Write-Host "  [✓] Postgres is healthy and ready." -ForegroundColor Green

# -------------------------------------------------------------
# Stage 5: Deliver Services (Backend & Frontend)
# -------------------------------------------------------------
Write-Host "`n>>> [Stage 5/6] Delivering Services via Kustomize..." -ForegroundColor Yellow
$kustomizeFile = "ai-agent/k8s/kustomization.yaml"
$kustomizeContent = Get-Content $kustomizeFile -Raw
try {
    # Temporarily update tag
    $patchedContent = $kustomizeContent -replace "newTag:\s*.*", "newTag: $ImageTag"
    Set-Content -Path $kustomizeFile -Value $patchedContent -Encoding utf8

    kubectl apply -k ai-agent/k8s/

    Write-Host "  Waiting for Backend rollout..." -ForegroundColor Cyan
    kubectl rollout status deployment/ai-agent-backend -n ai-agent --timeout=180s

    Write-Host "  Waiting for Frontend rollout..." -ForegroundColor Cyan
    kubectl rollout status deployment/ai-agent-frontend -n ai-agent --timeout=180s

    Write-Host "  [✓] All services rolled out successfully." -ForegroundColor Green
} finally {
    # Restore original kustomization.yaml
    git checkout -- $kustomizeFile 2>$null
}

# -------------------------------------------------------------
# Stage 6: Verification & Smoke Tests
# -------------------------------------------------------------
Write-Host "`n>>> [Stage 6/6] Verifying Services & Running Smoke Tests..." -ForegroundColor Yellow
kubectl get all -n ai-agent

# Test Backend health on ephemeral test port 8088 using a PowerShell background job
$testPort = 8088
$pfJob = Start-Job -ScriptBlock {
    param($port)
    kubectl port-forward svc/ai-agent-backend "${port}:8000" -n ai-agent
} -ArgumentList $testPort

Write-Host "  Waiting for port-forward to establish on port $testPort..." -ForegroundColor Cyan
$connected = $false
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Seconds 1
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient("127.0.0.1", $testPort)
        if ($tcp.Connected) {
            $tcp.Close()
            $connected = $true
            break
        }
    } catch { }
}

if (-not $connected) {
    Write-Error "Failed to establish port-forward to svc/ai-agent-backend on port $testPort."
}

try {
    Write-Host "  Testing /healthz endpoint on port $testPort..." -ForegroundColor Cyan
    $health = Invoke-RestMethod -Uri "http://127.0.0.1:${testPort}/healthz" -Method Get
    Write-Host "  [✓] /healthz response: $($health | ConvertTo-Json -Compress)" -ForegroundColor Green

    Write-Host "  Testing /metrics endpoint on port $testPort..." -ForegroundColor Cyan
    $metrics = curl.exe -s -L "http://127.0.0.1:${testPort}/metrics"
    if ($metrics -match "python_info") {
        Write-Host "  [✓] /metrics verified: Prometheus metrics active." -ForegroundColor Green
    } else {
        Write-Warning "Could not verify python_info metric."
    }
} finally {
    Stop-Job $pfJob -ErrorAction SilentlyContinue
    Remove-Job $pfJob -Force -ErrorAction SilentlyContinue
}

Write-Host "`n=================================================================" -ForegroundColor Cyan
Write-Host "  Pipeline Test Passed Successfully! 🚀" -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Cyan
