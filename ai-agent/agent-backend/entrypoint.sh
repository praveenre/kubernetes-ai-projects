#!/bin/sh
set -e

python -c "
import os, sys
required = ['DIAGNOSTICS_MODEL_ID', 'REMEDIATION_MODEL_ID']
missing = [v for v in required if not os.getenv(v)]
if not (os.getenv('MESH_API_KEY') or os.getenv('OPENROUTER_API_KEY') or os.getenv('OPENAI_API_KEY')):
    missing.append('MESH_API_KEY / OPENROUTER_API_KEY / OPENAI_API_KEY')
if missing:
    sys.exit(f'Missing required env vars: {missing}')

from kubernetes import config
try:
    config.load_incluster_config()
except Exception as e:
    sys.exit(f'Cannot load in-cluster kubeconfig: {e}')

database_url = os.getenv('DATABASE_URL')
if database_url:
    import psycopg
    try:
        with psycopg.connect(database_url, connect_timeout=5) as conn:
            pass
    except Exception as e:
        sys.exit(f'DATABASE_URL is set but Postgres is unreachable: {e}')
"

exec uvicorn app.main:app --host 0.0.0.0 --port 8000
