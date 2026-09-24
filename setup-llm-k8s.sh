#!/bin/bash
set -e

# ==============================================================================
# Configuration
# ==============================================================================
CLUSTER_NAME="llm-dev-cluster"
NAMESPACE="llm-inference"
# Set to 'true' if using Minikube with GPUs, or EKS/AKS GPU nodes. 
# Keep 'false' for standard 'kind' testing (CPU only).
USE_GPU="${1:-false}" 
MODEL_NAME="facebook/opt-125m" # Tiny model for testing K8s plumbing

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ==============================================================================
# 1. Prerequisites Check
# ==============================================================================
log "Checking prerequisites..."
for cmd in docker kubectl kind helm; do
    command -v $cmd >/dev/null 2>&1 || error "$cmd is not installed. Please install it first."
done
log "All prerequisites found."

# ==============================================================================
# 2. Create Local Cluster
# ==============================================================================
log "Creating Kind cluster: $CLUSTER_NAME..."
# Delete existing cluster if it exists to ensure a clean slate
kind delete cluster --name $CLUSTER_NAME 2>/dev/null || true

kind create cluster --name $CLUSTER_NAME --wait 5m

# ==============================================================================
# 3. Setup Namespace & GPU Plugin (If applicable)
# ==============================================================================
kubectl create namespace $NAMESPACE
kubectl config set-context --current --namespace=$NAMESPACE

if [ "$USE_GPU" = "true" ]; then
    log "GPU Mode enabled. Installing NVIDIA Device Plugin..."
    kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.15.0/deployments/static/nvidia-device-plugin.yml
    log "Waiting for NVIDIA Device Plugin to be ready..."
    kubectl wait --for=condition=ready pod -l name=nvidia-device-plugin-ds --timeout=120s -n kube-system
else
    warn "CPU Mode enabled. Skipping NVIDIA Device Plugin. (Use 'true' flag for GPU nodes)."
fi

# ==============================================================================
# 4. Deploy vLLM
# ==============================================================================
log "Adding vLLM Helm repository..."
helm repo add vllm https://vllm-project.github.io/vllm-helm
helm repo update

log "Deploying vLLM with model: $MODEL_NAME..."

if [ "$USE_GPU" = "true" ]; then
    # GPU Configuration for EKS/AKS/Minikube
    helm install vllm vllm/vllm \
        --namespace $NAMESPACE \
        --set model.name=$MODEL_NAME \
        --set replicaCount=1 \
        --set resources.limits."nvidia\.com/gpu"=1 \
        --set nodeSelector."nvidia\.com/gpu"=present \
        --set tolerations[0].key="nvidia\.com/gpu" \
        --set tolerations[0].operator="Exists" \
        --set tolerations[0].effect="NoSchedule"
else
    # CPU Configuration for local Kind testing
    helm install vllm vllm/vllm \
        --namespace $NAMESPACE \
        --set model.name=$MODEL_NAME \
        --set replicaCount=1 \
        --set resources.limits.cpu="2" \
        --set resources.limits.memory="4Gi"
fi

log "Waiting for vLLM pod to be ready (this may take a few minutes to download the model)..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vllm --timeout=300s -n $NAMESPACE

# ==============================================================================
# 5. Expose Service & Test
# ==============================================================================
log "Setting up Port Forwarding to test the API locally..."
log "Forwarding localhost:8000 to vLLM service..."

# Kill any existing port-forward on 8000
lsof -ti:8000 | xargs kill -9 2>/dev/null || true

kubectl port-forward svc/vllm 8000:8000 -n $NAMESPACE &
PORT_FORWARD_PID=$!

sleep 3
log "vLLM is running! Testing endpoint..."

# Test the OpenAI-compatible endpoint
curl -s http://localhost:8000/v1/models | jq . || warn "jq not installed, raw output:" && curl -s http://localhost:8000/v1/models

log "================================================================"
log "SUCCESS! Your local LLM Kubernetes environment is ready."
log "API Endpoint: http://localhost:8000/v1"
log "To stop port forwarding: kill $PORT_FORWARD_PID"
log "To delete cluster: kind delete cluster --name $CLUSTER_NAME"
log "================================================================"

# Keep script running so port-forward stays alive
wait $PORT_FORWARD_PID