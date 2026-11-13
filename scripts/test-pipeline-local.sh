#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG="local-test-$((RANDOM % 9000 + 1000))"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "================================================================="
echo "  Kubernetes AI Agent - Local CI/CD Pipeline Execution"
echo "  (Simulating Jenkins Stages against Local Infrastructure)"
echo "================================================================="

# Stage 1: Lint & Manifest Validation
echo -e "\n>>> [Stage 1/6] Lint & Manifest Validation..."
python3 -m py_compile "${ROOT_DIR}/ai-agent/agent-backend/app/main.py"
python3 -m py_compile "${ROOT_DIR}/ai-agent/agent-backend/app/infra/llm.py"
python3 -m py_compile "${ROOT_DIR}/ai-agent/agent-backend/app/agent/graph.py"
python3 -m py_compile "${ROOT_DIR}/ai-agent/agent-backend/app/agent/nodes.py"
kubectl kustomize "${ROOT_DIR}/ai-agent/k8s/" > /dev/null
echo "  [✓] Linting and manifests validated."

# Stage 2: Infrastructure Provisioning / Cluster Check
echo -e "\n>>> [Stage 2/6] Infra Provisioning (k3d Cluster Check & Setup)..."
chmod +x "${SCRIPT_DIR}/setup-k3d.sh"
"${SCRIPT_DIR}/setup-k3d.sh"

ACTIVE_CLUSTER=$(cat "${ROOT_DIR}/.k3d-active-cluster" 2>/dev/null || echo "ai-agent-cluster")
echo "  Active Target Cluster: ${ACTIVE_CLUSTER}"

# Stage 3: Build & Import Images into k3d
echo -e "\n>>> [Stage 3/6] Building & Importing Images into k3d..."
BACKEND_IMG="devopscube/ai-agent-backend:${IMAGE_TAG}"
FRONTEND_IMG="devopscube/ai-agent-frontend:${IMAGE_TAG}"

echo "  Building Backend Image: ${BACKEND_IMG}..."
docker build -t "${BACKEND_IMG}" "${ROOT_DIR}/ai-agent/agent-backend"

echo "  Building Frontend Image: ${FRONTEND_IMG}..."
docker build -t "${FRONTEND_IMG}" "${ROOT_DIR}/ai-agent/agent-interface"

echo "  Importing Images into k3d Cluster '${ACTIVE_CLUSTER}'..."
k3d image import "${BACKEND_IMG}" "${FRONTEND_IMG}" -c "${ACTIVE_CLUSTER}"
echo "  [✓] Images imported into k3d."

# Stage 4: Deploy Database Infrastructure (Postgres)
echo -e "\n>>> [Stage 4/6] Deploying Postgres Database & Secrets..."
kubectl apply -f "${ROOT_DIR}/ai-agent/k8s/manifests/namespace.yaml"
kubectl apply -f "${ROOT_DIR}/ai-agent/k8s/manifests/configmap.yaml"

MESH_KEY="${MESH_API_KEY:-}"
if [ -z "${MESH_KEY}" ] && [ -f "${ROOT_DIR}/ai-agent/agent-backend/.env" ]; then
    MESH_KEY=$(grep -E '^MESH_API_KEY=' "${ROOT_DIR}/ai-agent/agent-backend/.env" | cut -d '=' -f2- | tr -d '"'"'"' || true)
fi
if [ -z "${MESH_KEY}" ]; then
    MESH_KEY="mock-ci-key-for-healthcheck"
fi

kubectl create secret generic ai-agent-secrets -n ai-agent \
  --from-literal=DATABASE_PASSWORD=changeme \
  --from-literal=MESH_API_KEY="${MESH_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic ai-agent-postgres-secrets -n ai-agent \
  --from-literal=POSTGRES_PASSWORD=changeme \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "${ROOT_DIR}/ai-agent/k8s/manifests/postgres.yaml"

echo "  Waiting for Postgres StatefulSet rollout..."
kubectl rollout status statefulset/ai-agent-postgres -n ai-agent --timeout=120s
echo "  [✓] Postgres is healthy and ready."

# Stage 5: Deliver Services (Backend & Frontend)
echo -e "\n>>> [Stage 5/6] Delivering Services via Kustomize..."
KUSTOMIZE_FILE="${ROOT_DIR}/ai-agent/k8s/kustomization.yaml"
cp "${KUSTOMIZE_FILE}" "${KUSTOMIZE_FILE}.bak"

trap 'mv "${KUSTOMIZE_FILE}.bak" "${KUSTOMIZE_FILE}" 2>/dev/null || true' EXIT

sed -i "s/newTag:.*/newTag: ${IMAGE_TAG}/g" "${KUSTOMIZE_FILE}"
kubectl apply -k "${ROOT_DIR}/ai-agent/k8s/"

echo "  Waiting for Backend rollout..."
kubectl rollout status deployment/ai-agent-backend -n ai-agent --timeout=180s

echo "  Waiting for Frontend rollout..."
kubectl rollout status deployment/ai-agent-frontend -n ai-agent --timeout=180s
echo "  [✓] Services rolled out successfully."

# Stage 6: Smoke Tests
echo -e "\n>>> [Stage 6/6] Verifying Services & Running Smoke Tests..."
kubectl get all -n ai-agent

TEST_PORT=8088
kubectl port-forward svc/ai-agent-backend ${TEST_PORT}:8000 -n ai-agent &
PF_PID=$!

echo "  Waiting for port-forward tunnel on port ${TEST_PORT}..."
for i in $(seq 1 15); do
    if curl -fail -s http://127.0.0.1:${TEST_PORT}/healthz > /dev/null 2>&1; then
        echo "  Port-forward listener is ready!"
        break
    fi
    sleep 1
done

echo "  Testing /healthz endpoint on port ${TEST_PORT}..."
curl -fail -s http://127.0.0.1:${TEST_PORT}/healthz

echo -e "\n  Testing /metrics endpoint on port ${TEST_PORT}..."
curl -fail -s -L http://127.0.0.1:${TEST_PORT}/metrics | grep "python_info"

kill $PF_PID || true

echo -e "\n================================================================="
echo "  Pipeline Test Passed Successfully! 🚀"
echo "================================================================="
