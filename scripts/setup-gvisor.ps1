# ==============================================================================
# Setup gVisor (runsc) and RuntimeClass on Local k3d Cluster
# ==============================================================================
param(
    [string]$ClusterName = ""
)

$ErrorActionPreference = "Stop"

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "  Installing gVisor (runsc) & Configuring RuntimeClass" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

# 1. Identify active k3d nodes
$activeCluster = $ClusterName
if (-not $activeCluster -and (Test-Path ".k3d-active-cluster")) {
    $activeCluster = (Get-Content ".k3d-active-cluster" -Raw).Trim()
}
if (-not $activeCluster) {
    $activeCluster = "harness-lab"
}

Write-Host "[1/5] Discovering cluster nodes for '$activeCluster'..." -ForegroundColor Yellow
$nodes = docker ps --filter "name=k3d-${activeCluster}" --format "{{.Names}}" | Where-Object { $_ -match "server|agent" -and $_ -notmatch "serverlb" }

if (-not $nodes) {
    Write-Host "No nodes found with prefix 'k3d-${activeCluster}'. Scanning for any running k3d nodes..." -ForegroundColor Yellow
    $nodes = docker ps --filter "name=k3d-" --format "{{.Names}}" | Where-Object { $_ -match "server|agent" -and $_ -notmatch "serverlb" }
}

if (-not $nodes) {
    Write-Error "No active k3d nodes found. Please start a k3d cluster first using scripts/setup-k3d.ps1"
}

Write-Host "Found nodes: $($nodes -join ', ')" -ForegroundColor Green

# 2. Download and unpack gVisor release binaries via Alpine container
Write-Host "`n[2/5] Downloading official gVisor (runsc) release package..." -ForegroundColor Yellow
docker volume create gvisor-bin | Out-Null
docker run --rm -v gvisor-bin:/out alpine:latest sh -c "apk add --no-cache curl tar zstd && curl -fsSL https://storage.googleapis.com/gvisor/releases/release/latest/x86_64/gvisor.tar.zstd | tar --zstd -xf - -C /out && chmod +x /out/runsc /out/containerd-shim-runsc-v1 /out/gvisor-bin/*"

$tempDir = Join-Path $PWD ".gvisor-tmp"
if (Test-Path $tempDir) { Remove-Item -Recurse -Force $tempDir }
New-Item -ItemType Directory -Path $tempDir | Out-Null

docker run --rm -v gvisor-bin:/src -v "${PWD}:/host" alpine:latest sh -c "cp -r /src/* /host/.gvisor-tmp/"

# 3. Copy binaries & containerd configuration into each node
Write-Host "`n[3/5] Installing gVisor into cluster nodes and configuring containerd..." -ForegroundColor Yellow
$tomlContent = @"
[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
"@
$localToml = Join-Path $PWD ".runsc.toml"
Set-Content -Path $localToml -Value $tomlContent

foreach ($node in $nodes) {
    Write-Host "  -> Configuring $node..." -ForegroundColor Cyan
    docker cp "$tempDir/runsc" "${node}:/bin/runsc"
    docker cp "$tempDir/containerd-shim-runsc-v1" "${node}:/bin/containerd-shim-runsc-v1"
    docker cp "$tempDir/gvisor-bin" "${node}:/bin/gvisor-bin"
    docker exec $node chmod +x /bin/runsc /bin/containerd-shim-runsc-v1
    
    docker exec $node mkdir -p /var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d
    docker cp $localToml "${node}:/var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d/runsc.toml"
}

# Clean up temp files
Remove-Item -Force $localToml -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
docker volume rm gvisor-bin 2>$null | Out-Null

# 4. Restart nodes to activate containerd runsc runtime
Write-Host "`n[4/5] Restarting node containers to reload containerd..." -ForegroundColor Yellow
foreach ($node in $nodes) {
    docker restart $node | Out-Null
}

Write-Host "Waiting for Kubernetes API server to become ready..." -ForegroundColor Cyan
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 2
    $null = kubectl get nodes 2>$null
    if ($LASTEXITCODE -eq 0) {
        break
    }
}
kubectl wait --for=condition=Ready nodes --all --timeout=60s

# 5. Apply RuntimeClass and verify
Write-Host "`n[5/5] Creating Kubernetes RuntimeClass 'gvisor'..." -ForegroundColor Yellow
kubectl apply -f gvisor/runtimeclass.yaml

Write-Host "Registered RuntimeClasses:" -ForegroundColor Green
kubectl get runtimeclass gvisor

Write-Host "`nVerifying sandboxed pod execution..." -ForegroundColor Yellow
kubectl delete pod gvisor-smoke-test --ignore-not-found=true 2>$null
kubectl apply -f gvisor/test-pod.yaml

for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Seconds 1
    $phase = (kubectl get pod gvisor-smoke-test -o jsonpath='{.status.phase}' 2>$null)
    if ($phase -match "Running|Succeeded") {
        break
    }
}
Start-Sleep -Seconds 1

$logs = kubectl logs gvisor-smoke-test 2>$null
Write-Host $logs

if ($logs -match "Starting gVisor") {
    Write-Host "`n[✓] gVisor installation & RuntimeClass verified successfully! Sandbox isolation active." -ForegroundColor Green
} else {
    Write-Warning "Could not find 'Starting gVisor' in pod logs."
}

kubectl delete pod gvisor-smoke-test --ignore-not-found=true 2>$null

Write-Host "`n=================================================================" -ForegroundColor Cyan
Write-Host "  gVisor & RuntimeClass Setup Complete!" -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Cyan
