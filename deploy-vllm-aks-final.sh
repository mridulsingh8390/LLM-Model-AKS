#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# Prerequisite check
# =============================================================================
for cmd in kubectl helm htpasswd openssl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: $cmd not found. Please install it before running this script."
        exit 1
    fi
done

# Use environment variables in automation/CI
VLLM_PASSWORD="${VLLM_PASSWORD:-REPLACE_WITH_A_STRONG_PASSWORD}"
VLLM_API_KEY="${VLLM_API_KEY:-$(openssl rand -hex 32)}"
MODEL_NAME="${MODEL_NAME:-meta-llama/Llama-3.1-8B-Instruct}"
HF_TOKEN="${HF_TOKEN:-}"

if [ "${VLLM_PASSWORD}" = "REPLACE_WITH_A_STRONG_PASSWORD" ]; then
    echo "ERROR: Set VLLM_PASSWORD environment variable before running this script."
    echo "Example: export VLLM_PASSWORD='MySuperSecretPassword123!'"
    exit 1
fi

# Ensure temporary auth file is cleaned up
trap 'rm -f auth.txt' EXIT

echo "=== vLLM AKS + Application Gateway Deployment Helper ==="

# 1. Verify prerequisites
echo "[1/8] Verifying prerequisites..."
kubectl get nodes --show-labels | grep -E 'accelerator=nvidia|sku=gpu' || echo "WARNING: No GPU nodes found with expected labels."
kubectl get sc managed-csi-premium || echo "WARNING: managed-csi-premium storage class not found."
kubectl get pods -n kube-system | grep -i ingress-appgw || echo "WARNING: AGIC controller not found in kube-system."
kubectl describe nodes | grep -A5 -B2 'nvidia.com/gpu' || echo "WARNING: nvidia.com/gpu resources not detected on nodes."

# 2. Create namespace and secrets
echo "[2/8] Creating secrets..."
htpasswd -nb admin "${VLLM_PASSWORD}" > auth.txt
kubectl create namespace vllm --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic vllm-basic-auth \
  --from-file=auth=auth.txt \
  -n vllm \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic vllm-api-key \
  --from-literal=api-key="${VLLM_API_KEY}" \
  -n vllm \
  --dry-run=client -o yaml | kubectl apply -f -

if [ -n "${HF_TOKEN}" ]; then
  kubectl create secret generic hf-token \
    --from-literal=token="${HF_TOKEN}" \
    -n vllm \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "Hugging Face token secret created."
else
  echo "WARNING: HF_TOKEN not set. Gated models (like Llama 3) will fail to download."
  echo "For production Llama deployments, set HF_TOKEN and re-run."
fi

# 3. Deploy monitoring stack (Prometheus + Grafana + DCGM)
echo "[3/8] Deploying monitoring stack..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.adminPassword="${VLLM_PASSWORD}" \
  --set prometheus.prometheusSpec.retention=7d \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=managed-csi-premium \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=50Gi \
  --set alertmanager.enabled=false \
  --wait

echo "Applying vLLM monitoring dashboard and DCGM exporter..."
# FIXED: Explicitly define the monitoring manifest file
kubectl apply -f "${SCRIPT_DIR}/vllm-monitoring-final.yaml"

# 4. Reminders for manual changes
MANIFEST="${SCRIPT_DIR}/vllm-production-aks-appgw-final.yaml"
echo "[4/8] REMINDER: Ensure you have updated the following in ${MANIFEST}:"
echo "  - MODEL_NAME: ${MODEL_NAME} (currently set in Deployment env)"
echo "  - host: vllm.example.com (Replace with your real DNS name)"
echo "  - nodeSelector: accelerator: nvidia (Verify your actual GPU-node label)"
echo "  - storageClassName: managed-csi-premium (Verify your AKS cluster's premium storage class)"

# 5. Deploy vLLM
echo "[5/8] Deploying vLLM resources..."
kubectl apply -f "${MANIFEST}"

echo "Waiting up to 15 minutes for the vLLM pod to become Ready (model download takes time)..."
if ! kubectl wait --for=condition=Ready pod -l app=vllm -n vllm --timeout=900s; then
    echo "ERROR: vLLM pod did not become Ready within 900 seconds."
    echo "--- Troubleshooting Info ---"
    kubectl get pods -n vllm -o wide
    kubectl describe pod -n vllm -l app=vllm
    echo "--- vLLM Container Logs ---"
    kubectl logs -n vllm deployment/vllm -c vllm --tail=50 || true
    echo "--- NGINX Container Logs ---"
    kubectl logs -n vllm deployment/vllm -c nginx-auth --tail=50 || true
    exit 1
fi

kubectl get pvc -n vllm
kubectl get pods -n vllm -o wide
kubectl get svc -n vllm
kubectl get ingress -n vllm

# 6. Verify the pod
echo "[6/8] Verifying pod status and logs..."
kubectl describe pod -n vllm -l app=vllm
echo "--- vLLM Logs ---"
kubectl logs -n vllm deployment/vllm -c vllm --tail=20
echo "--- NGINX Logs ---"
kubectl logs -n vllm deployment/vllm -c nginx-auth --tail=20

# 7. Test inside the cluster (Dual Auth: Basic + Bearer)
echo "[7/8] Testing inside the cluster..."
kubectl run vllm-test -n vllm \
  --rm --restart=Never \
  --image=curlimages/curl:8.10.1 -- \
  curl -s -u "admin:${VLLM_PASSWORD}" \
  -H "Authorization: Bearer ${VLLM_API_KEY}" \
  http://vllm-service/v1/models

# 8. Test completion endpoint (Dual Auth: Basic + Bearer)
echo "[8/8] Testing chat completion..."
kubectl run vllm-test-completion -n vllm \
  --rm --restart=Never \
  --image=curlimages/curl:8.10.1 -- \
  curl -s -X POST \
  -u "admin:${VLLM_PASSWORD}" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${VLLM_API_KEY}" \
  -d '{"model": "'"${MODEL_NAME}"'", "messages": [{"role": "user", "content": "Hello, are you working?"}], "max_tokens": 10}' \
  http://vllm-service/v1/chat/completions

echo ""
echo "=== Deployment script completed successfully ==="
echo ""
echo "Access Information:"
echo "  Grafana Dashboard: kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring"
echo "  URL: http://localhost:3000 (admin / ${VLLM_PASSWORD})"
echo ""
echo "To test through Application Gateway, run:"
echo "curl -u \"admin:${VLLM_PASSWORD}\" -H \"Authorization: Bearer ${VLLM_API_KEY}\" https://vllm.example.com/v1/models"
echo ""
echo "If Application Gateway returns 502/504, run:"
echo "  az network application-gateway show-backend-health --resource-group <RESOURCE_GROUP> --name <APPLICATION_GATEWAY_NAME> -o json"