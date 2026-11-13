# Bare-Metal k3d Cluster Setup & CI/CD Guide

This guide explains how to provision a local Kubernetes cluster from scratch using **k3d** on a bare-metal machine (Linux or Windows), and how the **GitHub Actions CI/CD** pipeline automates infrastructure provisioning before delivering application services.

---

## 1. Bare-Metal Machine Prerequisites

Before provisioning the cluster, ensure your bare-metal machine has **Docker** installed and running:

- **Linux (Ubuntu/Debian)**:
  ```bash
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker $USER && newgrp docker
  ```
- **Windows**:
  Install [Docker Desktop](https://docs.docker.com/desktop/install/windows-install/) and ensure the WSL2 backend is active.

---

## 2. One-Command k3d Cluster Setup

The repository provides automated provisioning scripts that install `k3d` and `kubectl` (if missing), configure port forwarding, and start the cluster:

### Linux / macOS / WSL2:
```bash
chmod +x scripts/setup-k3d.sh
./scripts/setup-k3d.sh
```

### Windows (PowerShell):
```powershell
.\scripts\setup-k3d.ps1
```

### Declarative Cluster Configuration:
Both scripts use the declarative spec defined in [ai-agent/k8s/k3d-config.yaml](../ai-agent/k8s/k3d-config.yaml):
- **1 Control Plane Node** (`server-0`)
- **1 Worker Agent Node** (`agent-0`)
- **Built-in LoadBalancer** exposing:
  - `8000:8000` — Agent Backend API
  - `3000:3000` — Next.js Chat Frontend
  - `5432:5432` — PostgreSQL Database
  - `80:80` — Traefik Ingress Router

---

## 3. Delivering Services on the Running Cluster

Once the cluster is up, deploy the application stack using Kustomize:

### Step 1: Deploy Namespace, ConfigMap & Secrets
```bash
# 1. Create namespace
kubectl apply -f ai-agent/k8s/manifests/namespace.yaml

# 2. Apply configuration
kubectl apply -f ai-agent/k8s/manifests/configmap.yaml

# 3. Create Secrets (replace your-key with your real Mesh API or OpenAI key)
kubectl create secret generic ai-agent-secrets -n ai-agent \
  --from-literal=DATABASE_PASSWORD=changeme \
  --from-literal=MESH_API_KEY="your-mesh-api-key"

kubectl create secret generic ai-agent-postgres-secrets -n ai-agent \
  --from-literal=POSTGRES_PASSWORD=changeme
```

### Step 2: Deploy Database & Storage
```bash
kubectl apply -f ai-agent/k8s/manifests/postgres.yaml

# Wait for database ready
kubectl rollout status statefulset/ai-agent-postgres -n ai-agent --timeout=120s
```

### Step 3: Deploy Backend & Frontend
```bash
kubectl apply -k ai-agent/k8s/

# Wait for rollouts
kubectl rollout status deployment/ai-agent-backend -n ai-agent --timeout=180s
kubectl rollout status deployment/ai-agent-frontend -n ai-agent --timeout=180s
```

Access the UI at: **`http://localhost:3000`**

---

## 4. GitHub Actions CI/CD Pipeline

The automated pipeline is defined in [.github/workflows/ci-cd.yaml](../.github/workflows/ci-cd.yaml).

### Execution Flow:

```
┌────────────────────────────────────────────────────────┐
│  Stage 1: Lint & Validate                              │
│  - Compile Python modules                              │
│  - Validate Kustomize manifests                        │
└──────────────────────────┬─────────────────────────────┘
                           │
┌──────────────────────────▼─────────────────────────────┐
│  Stage 2: Infrastructure Provisioning (k3d)             │
│  - Install k3d CLI on runner                           │
│  - Execute ./scripts/setup-k3d.sh                      │
│  - Wait for Kubernetes nodes to reach Ready state       │
└──────────────────────────┬─────────────────────────────┘
                           │
┌──────────────────────────▼─────────────────────────────┐
│  Stage 3: Image Build & In-Cluster Import               │
│  - Build backend (Python 3.12) & frontend (Next.js 16) │
│  - k3d image import (no external registry required)    │
└──────────────────────────┬─────────────────────────────┘
                           │
┌──────────────────────────▼─────────────────────────────┐
│  Stage 4: Service Delivery (Database -> Services)      │
│  - Deliver Postgres StatefulSet & verify PVC binding   │
│  - Deliver Backend Deployment & Frontend Deployment    │
└──────────────────────────┬─────────────────────────────┘
                           │
┌──────────────────────────▼─────────────────────────────┐
│  Stage 5: Smoke Tests & Verification                   │
│  - Query /healthz probe                                │
│  - Query /metrics Prometheus endpoint                  │
└────────────────────────────────────────────────────────┘
```

### Required GitHub Secrets:
To allow the CI pipeline to run live LLM diagnosis during smoke tests, add:
- `MESH_API_KEY`: Your Mesh API gateway key (Settings → Secrets and variables → Actions).
