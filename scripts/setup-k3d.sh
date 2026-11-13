#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${1:-ai-agent-cluster}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../ai-agent/k8s/k3d-config.yaml"

echo "================================================================="
echo "  Kubernetes AI Agent - Bare-Metal k3d Cluster Setup"
echo "================================================================="

# 1. Verify Docker Engine
echo "[1/5] Checking Docker..."
if ! command -v docker >/dev/null 2>&1; then
  echo "Error: docker is not installed. Please install Docker first: https://docs.docker.com/engine/install/" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Error: Docker daemon is not running. Please start Docker and retry." >&2
  exit 1
fi
echo "Docker is running."

# 2. Check / Install k3d CLI
echo "[2/5] Checking k3d CLI..."
if ! command -v k3d >/dev/null 2>&1; then
  echo "k3d not found. Downloading and installing k3d..."
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi
echo "k3d version: $(k3d version | head -n 1)"

# 3. Check / Install kubectl
echo "[3/5] Checking kubectl..."
if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found. Installing kubectl..."
  K8S_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
  curl -LO "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl"
  chmod +x kubectl
  if [ "$(id -u)" -eq 0 ]; then
    mv kubectl /usr/local/bin/
  else
    sudo mv kubectl /usr/local/bin/
  fi
fi
echo "kubectl is ready."

# 4. Check for Running k3d Cluster or Provision Fresh
echo "[4/5] Checking k3d cluster state..."

# Detect if ANY k3d cluster is already running locally (servers running > 0)
ACTIVE_RUNNING_CLUSTER=$(k3d cluster list --no-headers 2>/dev/null | awk '$2 ~ /^[1-9]/ {print $1}' | head -n 1 || true)

TARGET_CLUSTER=""

if [ -n "${1:-}" ]; then
  # User explicitly specified a cluster name
  REQ_CLUSTER="$1"
  STATUS=$(k3d cluster list --no-headers 2>/dev/null | awk -v c="${REQ_CLUSTER}" '$1 == c {print $2}' || true)
  if [[ "${STATUS}" =~ ^[1-9] ]]; then
    echo "[✓] k3d cluster '${REQ_CLUSTER}' is ALREADY RUNNING locally. Skipping fresh installation."
    TARGET_CLUSTER="${REQ_CLUSTER}"
  elif [ -n "${STATUS}" ]; then
    echo "[!] k3d cluster '${REQ_CLUSTER}' exists but is stopped. Starting cluster..."
    k3d cluster start "${REQ_CLUSTER}"
    TARGET_CLUSTER="${REQ_CLUSTER}"
  else
    echo "[+] Cluster '${REQ_CLUSTER}' does not exist. Creating fresh k3d cluster '${REQ_CLUSTER}'..."
    if [ -f "${CONFIG_FILE}" ]; then
      k3d cluster create "${REQ_CLUSTER}" --config "${CONFIG_FILE}"
    else
      k3d cluster create "${REQ_CLUSTER}" \
        --servers 1 \
        --agents 1 \
        -p "8000:8000@loadbalancer" \
        -p "3000:3000@loadbalancer" \
        -p "5432:5432@loadbalancer" \
        -p "80:80@loadbalancer" \
        --wait
    fi
    TARGET_CLUSTER="${REQ_CLUSTER}"
  fi
else
  # No cluster name argument passed: check if any cluster is already running
  if [ -n "${ACTIVE_RUNNING_CLUSTER}" ]; then
    echo "[✓] Detected active k3d cluster '${ACTIVE_RUNNING_CLUSTER}' already running locally. Skipping fresh installation."
    TARGET_CLUSTER="${ACTIVE_RUNNING_CLUSTER}"
  else
    TARGET_CLUSTER="ai-agent-cluster"
    STATUS=$(k3d cluster list --no-headers 2>/dev/null | awk -v c="${TARGET_CLUSTER}" '$1 == c {print $2}' || true)
    if [[ "${STATUS}" =~ ^[1-9] ]]; then
      echo "[✓] k3d cluster '${TARGET_CLUSTER}' is already running. Skipping fresh installation."
    elif [ -n "${STATUS}" ]; then
      echo "[!] Starting stopped cluster '${TARGET_CLUSTER}'..."
      k3d cluster start "${TARGET_CLUSTER}"
    else
      echo "[+] Creating new k3d cluster '${TARGET_CLUSTER}'..."
      if [ -f "${CONFIG_FILE}" ]; then
        k3d cluster create "${TARGET_CLUSTER}" --config "${CONFIG_FILE}"
      else
        k3d cluster create "${TARGET_CLUSTER}" \
          --servers 1 \
          --agents 1 \
          -p "8000:8000@loadbalancer" \
          -p "3000:3000@loadbalancer" \
          -p "5432:5432@loadbalancer" \
          -p "80:80@loadbalancer" \
          --wait
      fi
    fi
  fi
fi

# Switch kubectl context to target cluster and record active cluster name
kubectl config use-context "k3d-${TARGET_CLUSTER}" || true
echo "${TARGET_CLUSTER}" > "${SCRIPT_DIR}/../.k3d-active-cluster"

# 5. WSL2 / Windows Address Fix (if running inside WSL)
if grep -qi microsoft /proc/version 2>/dev/null; then
  echo "Detected WSL2 environment. Adjusting kubeconfig host address..."
  PORT=$(kubectl config view -o jsonpath="{.clusters[?(@.name=='k3d-${TARGET_CLUSTER}')].cluster.server}" | awk -F: '{print $3}')
  if [ -n "${PORT}" ]; then
    kubectl config set-cluster "k3d-${TARGET_CLUSTER}" --server="https://127.0.0.1:${PORT}" --tls-server-name=0.0.0.0 || true
  fi
fi

# 6. Verify Node Readiness
echo "[5/5] Verifying cluster readiness..."
kubectl wait --for=condition=Ready nodes --all --timeout=90s

echo "================================================================="
echo "  Target cluster '${TARGET_CLUSTER}' is ready and active!"
echo "================================================================="
kubectl get nodes -o wide

