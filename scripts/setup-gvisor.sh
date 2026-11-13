#!/usr/bin/env bash
# ==============================================================================
# Setup gVisor (runsc) and RuntimeClass on Local k3d Cluster (Linux/macOS)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLUSTER_NAME="${1:-}"
if [ -z "$CLUSTER_NAME" ] && [ -f "${ROOT_DIR}/.k3d-active-cluster" ]; then
    CLUSTER_NAME=$(cat "${ROOT_DIR}/.k3d-active-cluster" 2>/dev/null | tr -d '[:space:]')
fi
if [ -z "$CLUSTER_NAME" ]; then
    CLUSTER_NAME="harness-lab"
fi

echo "================================================================="
echo "  Installing gVisor (runsc) & Configuring RuntimeClass"
echo "================================================================="

# 1. Discover nodes
echo -e "\n[1/5] Discovering cluster nodes for '${CLUSTER_NAME}'..."
NODES=$(docker ps --filter "name=k3d-${CLUSTER_NAME}" --format "{{.Names}}" | grep -E "server|agent" | grep -v "serverlb" || true)

if [ -z "$NODES" ]; then
    echo "Scanning for any running k3d nodes..."
    NODES=$(docker ps --filter "name=k3d-" --format "{{.Names}}" | grep -E "server|agent" | grep -v "serverlb" || true)
fi

if [ -z "$NODES" ]; then
    echo "Error: No active k3d nodes found. Please start a k3d cluster first using scripts/setup-k3d.sh" >&2
    exit 1
fi

echo "Found nodes: ${NODES}"

# 2. Download gVisor archive
echo -e "\n[2/5] Downloading official gVisor (runsc) release package..."
docker volume create gvisor-bin >/dev/null
docker run --rm -v gvisor-bin:/out alpine:latest sh -c "apk add --no-cache curl tar zstd && curl -fsSL https://storage.googleapis.com/gvisor/releases/release/latest/x86_64/gvisor.tar.zstd | tar --zstd -xf - -C /out && chmod +x /out/runsc /out/containerd-shim-runsc-v1 /out/gvisor-bin/*"

TEMP_DIR="${ROOT_DIR}/.gvisor-tmp"
rm -rf "${TEMP_DIR}"
mkdir -p "${TEMP_DIR}"

docker run --rm -v gvisor-bin:/src -v "${ROOT_DIR}:/host" alpine:latest sh -c "cp -r /src/* /host/.gvisor-tmp/"

# 3. Copy binaries & containerd configuration into each node
echo -e "\n[3/5] Installing gVisor into cluster nodes and configuring containerd..."
for node in $NODES; do
    echo "  -> Configuring $node..."
    docker cp "${TEMP_DIR}/runsc" "${node}:/bin/runsc"
    docker cp "${TEMP_DIR}/containerd-shim-runsc-v1" "${node}:/bin/containerd-shim-runsc-v1"
    docker cp "${TEMP_DIR}/gvisor-bin" "${node}:/bin/gvisor-bin"
    docker exec "$node" chmod +x /bin/runsc /bin/containerd-shim-runsc-v1
    docker exec "$node" mkdir -p /var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d
    docker exec "$node" sh -c 'cat << "EOF" > /var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d/runsc.toml
[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
EOF'
done

rm -rf "${TEMP_DIR}"
docker volume rm gvisor-bin >/dev/null

# 4. Restart nodes to activate containerd runsc runtime
echo -e "\n[4/5] Restarting node containers to reload containerd..."
for node in $NODES; do
    docker restart "$node" >/dev/null
done

echo "Waiting for Kubernetes API server to become ready..."
for i in $(seq 1 30); do
    if kubectl get nodes >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

kubectl wait --for=condition=Ready nodes --all --timeout=60s

# 5. Apply RuntimeClass and verify
echo -e "\n[5/5] Creating Kubernetes RuntimeClass 'gvisor'..."
kubectl apply -f "${ROOT_DIR}/gvisor/runtimeclass.yaml"

echo "Registered RuntimeClasses:"
kubectl get runtimeclass gvisor

echo -e "\nVerifying sandboxed pod execution..."
kubectl delete pod gvisor-smoke-test --ignore-not-found=true 2>/dev/null || true
kubectl apply -f "${ROOT_DIR}/gvisor/test-pod.yaml"

for i in $(seq 1 20); do
    PHASE=$(kubectl get pod gvisor-smoke-test -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "$PHASE" =~ Running|Succeeded ]]; then
        break
    fi
    sleep 1
done
sleep 1

LOGS=$(kubectl logs gvisor-smoke-test 2>/dev/null || true)
echo "${LOGS}"

if echo "${LOGS}" | grep -q "Starting gVisor"; then
    echo -e "\n[✓] gVisor installation & RuntimeClass verified successfully! Sandbox isolation active."
else
    echo "Warning: Could not confirm 'Starting gVisor' in test pod logs."
fi

kubectl delete pod gvisor-smoke-test --ignore-not-found=true 2>/dev/null || true

echo -e "\n================================================================="
echo "  gVisor & RuntimeClass Setup Complete!"
echo "================================================================="
