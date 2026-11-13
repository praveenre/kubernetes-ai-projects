# K8s Diagnose & Remediate Agent  

A LangGraph multi-agent that diagnoses and (with human approval) remediates Kubernetes problems
using OpenAI-compatible models (such as Mesh API, OpenRouter, or OpenAI - see
`agent-backend/app/infra/llm.py`). Exposed via a FastAPI backend and a Next.js chat UI, with a
`diagnose -> propose fix -> [human approval] -> apply -> verify -> retry` loop
(`agent-backend/app/agent/`).

## Structure

```
ai-agent/
  agent-backend/    Python/FastAPI agent
  agent-interface/  Next.js chat UI
  k8s/              Kubernetes deployment manifests, RBAC, and deploy instructions
```

## Local development

```sh
cd agent-backend
cp .env.example .env   # fill in MESH_API_KEY / OPENROUTER_API_KEY and model IDs
pip install -r requirements.txt
uvicorn app.main:app          # backend on http://127.0.0.1:8000

cd ../agent-interface
npm install
npm run dev              # frontend on http://localhost:3000
```

Requires a working `kubectl` context (`~/.kube/config`) pointing at the cluster you want the agent
to diagnose/remediate (e.g. a local `k3d` cluster), and an API key for your chosen LLM provider
in `agent-backend/.env`.

## Deploying to Kubernetes

See [`k8s/README.md`](k8s/README.md) for prerequisites, Dockerfiles, manifests (Deployment,
Service, RBAC, NetworkPolicy, Postgres-backed durable memory, health probes), and a phased
step-by-step deploy guide.

## API endpoints

All served by the FastAPI backend (`agent-backend/app/main.py`):

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/health` | Basic health check |
| GET | `/healthz` | Liveness probe (also reports `require_approval`) |
| GET | `/readyz` | Readiness probe - checks Kubernetes API and LLM client connectivity |
| GET | `/api/usage` | Token usage/cost tracking |
| POST | `/api/query` | Submit a diagnosis request; starts a new agent session |
| POST | `/api/decision` | Approve or reject a proposed fix |
| POST | `/api/retry` | Retry remediation after a failed verification |
| POST | `/api/select-issues` | Choose which of the diagnosed issues to remediate |
| POST | `/api/guidance` | Give the agent human guidance before its next attempt |
| GET | `/metrics` | Prometheus metrics (mounted sub-app) |

## Key files

| File | Purpose |
|---|---|
| `agent-backend/app/agent/` | LangGraph state machine - the diagnose/propose/apply/verify/retry loop |
| `agent-backend/app/tools/` | Kubernetes API tools the agent calls (read-only diagnostics + write remediation) |
| `agent-backend/app/main.py` | FastAPI backend - `/api/query`, `/api/decision`, `/api/retry`, `/healthz`, `/readyz`, `/metrics` |
| `agent-backend/app/infra/llm.py` | LLM model client factory (Mesh API, OpenRouter, OpenAI) |
| `agent-backend/app/infra/checkpointer.py` | LangGraph checkpoint storage - Postgres (connection pool) if `DATABASE_URL` is set, in-memory otherwise |
| `agent-backend/app/infra/usage_tracker.py` | Token usage/cost tracking |
| `agent-backend/Dockerfile` | Backend container image |
| `agent-interface/` | Next.js chat UI (own `Dockerfile`) |
| `k8s/` | Kubernetes deployment manifests, RBAC, and deploy instructions |
