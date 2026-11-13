pipeline {
    agent any

    options {
        timeout(time: 30, unit: 'MINUTES')
        ansiColor('xterm')
        disableConcurrentBuilds()
    }

    environment {
        // Build image tag for this pipeline execution
        IMAGE_TAG = "jenkins-${BUILD_NUMBER}"
        // Fallback mock key if MESH_API_KEY credential is not pre-configured in Jenkins
        MESH_KEY = credentials('MESH_API_KEY') ?: 'mock-ci-key-for-healthcheck'
    }

    stages {
        stage('Lint & Manifest Validation') {
            steps {
                echo "================================================================="
                echo "  Stage 1: Linting Python & Validating Kubernetes Manifests"
                echo "================================================================="
                sh '''
                    echo "Checking Python syntax..."
                    python3 -m py_compile ai-agent/agent-backend/app/main.py
                    python3 -m py_compile ai-agent/agent-backend/app/infra/llm.py
                    python3 -m py_compile ai-agent/agent-backend/app/agent/graph.py
                    python3 -m py_compile ai-agent/agent-backend/app/agent/nodes.py

                    echo "Validating Kustomize manifests..."
                    kubectl kustomize ai-agent/k8s/ > /dev/null
                    echo "Validation passed successfully."
                '''
            }
        }

        stage('Infra Provisioning (k3d Cluster Check & Setup)') {
            steps {
                echo "================================================================="
                echo "  Stage 2: Infrastructure Provisioning (k3d Cluster)"
                echo "================================================================="
                sh '''
                    chmod +x scripts/setup-k3d.sh
                    # setup-k3d.sh detects if a k3d cluster is already running locally.
                    # If running, it reuses it and skips fresh install.
                    ./scripts/setup-k3d.sh

                    kubectl cluster-info
                    kubectl get nodes -o wide
                '''
            }
        }

        stage('Build & Import Container Images') {
            steps {
                echo "================================================================="
                echo "  Stage 3: Building Container Images & Importing into k3d"
                echo "================================================================="
                sh '''
                    ACTIVE_CLUSTER=$(cat .k3d-active-cluster 2>/dev/null || echo "ai-agent-cluster")
                    echo "Target k3d Cluster: ${ACTIVE_CLUSTER}"

                    echo "Building backend image (tag: ${IMAGE_TAG})..."
                    docker build -t devopscube/ai-agent-backend:${IMAGE_TAG} ai-agent/agent-backend

                    echo "Building frontend image (tag: ${IMAGE_TAG})..."
                    docker build -t devopscube/ai-agent-frontend:${IMAGE_TAG} ai-agent/agent-interface

                    echo "Importing images into k3d cluster '${ACTIVE_CLUSTER}'..."
                    k3d image import devopscube/ai-agent-backend:${IMAGE_TAG} \
                                     devopscube/ai-agent-frontend:${IMAGE_TAG} \
                                     -c "${ACTIVE_CLUSTER}"
                '''
            }
        }

        stage('Deploy Database Infrastructure (Postgres)') {
            steps {
                echo "================================================================="
                echo "  Stage 4: Deploying Postgres Database & Secrets"
                echo "================================================================="
                sh '''
                    kubectl apply -f ai-agent/k8s/manifests/namespace.yaml
                    kubectl apply -f ai-agent/k8s/manifests/configmap.yaml

                    API_KEY="${MESH_KEY}"
                    if [ -z "$API_KEY" ] || [ "$API_KEY" = "null" ]; then
                        API_KEY="mock-ci-key-for-healthcheck"
                    fi

                    kubectl create secret generic ai-agent-secrets -n ai-agent \
                      --from-literal=DATABASE_PASSWORD=changeme \
                      --from-literal=MESH_API_KEY="$API_KEY" \
                      --dry-run=client -o yaml | kubectl apply -f -

                    kubectl create secret generic ai-agent-postgres-secrets -n ai-agent \
                      --from-literal=POSTGRES_PASSWORD=changeme \
                      --dry-run=client -o yaml | kubectl apply -f -

                    kubectl apply -f ai-agent/k8s/manifests/postgres.yaml

                    echo "Waiting for Postgres StatefulSet rollout..."
                    kubectl rollout status statefulset/ai-agent-postgres -n ai-agent --timeout=120s
                    kubectl get pods,pvc -n ai-agent
                '''
            }
        }

        stage('Deliver Services (Backend & Frontend)') {
            steps {
                echo "================================================================="
                echo "  Stage 5: Delivering Services via Kustomize"
                echo "================================================================="
                sh '''
                    cd ai-agent/k8s
                    # Update image tags to match current build
                    sed -i "s/newTag:.*/newTag: ${IMAGE_TAG}/g" kustomization.yaml
                    kubectl apply -k .
                    cd ../..

                    echo "Waiting for Backend Deployment rollout..."
                    kubectl rollout status deployment/ai-agent-backend -n ai-agent --timeout=180s

                    echo "Waiting for Frontend Deployment rollout..."
                    kubectl rollout status deployment/ai-agent-frontend -n ai-agent --timeout=180s

                    kubectl get all -n ai-agent
                '''
            }
        }

        stage('Verification & Smoke Tests') {
            steps {
                echo "================================================================="
                echo "  Stage 6: Smoke Testing Endpoints"
                echo "================================================================="
                sh '''
                    TEST_PORT=8088
                    kubectl port-forward svc/ai-agent-backend ${TEST_PORT}:8000 -n ai-agent &
                    PF_PID=$!
                    sleep 5

                    echo "Testing /healthz endpoint on port ${TEST_PORT}..."
                    curl -fail -s http://127.0.0.1:${TEST_PORT}/healthz

                    echo "Testing /metrics endpoint on port ${TEST_PORT}..."
                    curl -fail -s -L http://127.0.0.1:${TEST_PORT}/metrics | grep "python_info"

                    kill $PF_PID || true
                    echo "Smoke tests passed successfully!"
                '''
            }
        }
    }

    post {
        always {
            echo "Cleaning up local workspace git modifications..."
            sh 'git checkout -- ai-agent/k8s/kustomization.yaml 2>/dev/null || true'
        }
        success {
            echo "================================================================="
            echo "  Jenkins CI/CD Pipeline Completed Successfully! 🚀"
            echo "================================================================="
        }
        failure {
            echo "================================================================="
            echo "  Jenkins CI/CD Pipeline Failed! ❌"
            echo "================================================================="
            sh 'kubectl get pods,events -n ai-agent --sort-by=.metadata.creationTimestamp | tail -n 30 || true'
        }
    }
}
