#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Prerequisite check
# =============================================================================
if ! command -v htpasswd >/dev/null 2>&1; then
    echo "ERROR: htpasswd not found."
    echo "Install apache2-utils (Debian/Ubuntu) or httpd-tools (RHEL/Fedora)."
    exit 1
fi

# Use an environment variable in automation/CI; the placeholder makes
# the script self-documenting when run interactively.
OLLAMA_PASSWORD="${OLLAMA_PASSWORD:-REPLACE_WITH_A_STRONG_PASSWORD}"
if [ "${OLLAMA_PASSWORD}" = "REPLACE_WITH_A_STRONG_PASSWORD" ]; then
    echo "ERROR: Set OLLAMA_PASSWORD environment variable before running this script."
    echo "Example: export OLLAMA_PASSWORD='MySuperSecretPassword123!'"
    exit 1
fi

# Ensure temporary auth file is cleaned up even if the script exits unexpectedly
trap 'rm -f auth.txt' EXIT

echo "=== Ollama AKS + Application Gateway Deployment Helper ==="

# 1. Verify prerequisites
echo "[1/7] Verifying prerequisites..."
kubectl get nodes --show-labels | grep -E 'accelerator=nvidia|sku=gpu' || echo "WARNING: No GPU nodes found with expected labels."
kubectl get sc managed-csi-premium || echo "WARNING: managed-csi-premium storage class not found."
kubectl get pods -n kube-system | grep -i ingress-appgw || echo "WARNING: AGIC controller not found in kube-system."

# Verify GPU resource is visible:
kubectl describe nodes | grep -A5 -B2 'nvidia.com/gpu' || echo "WARNING: nvidia.com/gpu resources not detected on nodes."

# 2. Create the NGINX basic-auth secret
echo "[2/7] Creating NGINX basic-auth secret..."
htpasswd -nb admin "${OLLAMA_PASSWORD}" > auth.txt

kubectl create namespace ollama --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic ollama-basic-auth \
  --from-file=auth=auth.txt \
  -n ollama \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret created successfully."

# 3. Reminders for manual changes
MANIFEST="ollama-production-aks-appgw-final.yaml"
echo "[3/7] REMINDER: Ensure you have updated the following in ${MANIFEST}:"
echo "  - image: ollama/ollama:<tested-version>"
echo "  - host: ollama.example.com (Replace with your real DNS name)"
echo "  - nodeSelector: accelerator: nvidia (Verify your actual GPU-node label)"
echo "  - storageClassName: managed-csi-premium (Verify your AKS cluster's premium storage class)"

# 4. Deploy
echo "[4/7] Deploying resources..."
kubectl apply -f "${MANIFEST}"

echo "Waiting up to 10 minutes for the Ollama pod to become Ready..."
if ! kubectl wait --for=condition=Ready pod -l app=ollama -n ollama --timeout=600s; then
    echo "ERROR: Ollama pod did not become Ready within 600 seconds."
    echo "--- Troubleshooting Info ---"
    kubectl get pods -n ollama -o wide
    kubectl describe pod -n ollama -l app=ollama
    echo "--- Ollama Container Logs ---"
    kubectl logs -n ollama deployment/ollama -c ollama --tail=50 || true
    echo "--- NGINX Container Logs ---"
    kubectl logs -n ollama deployment/ollama -c nginx-auth --tail=50 || true
    exit 1
fi

kubectl get pvc -n ollama
kubectl get pods -n ollama -o wide
kubectl get svc -n ollama
kubectl get ingress -n ollama

# 5. Verify the pod
echo "[5/7] Verifying pod status and logs..."
kubectl describe pod -n ollama -l app=ollama
echo "--- Ollama Logs ---"
kubectl logs -n ollama deployment/ollama -c ollama --tail=20
echo "--- NGINX Logs ---"
kubectl logs -n ollama deployment/ollama -c nginx-auth --tail=20

# 6. Pull a model
echo "[6/7] Pulling model (llama3.1:8b)..."
kubectl exec -n ollama deployment/ollama -c ollama -- ollama pull llama3.1:8b
kubectl exec -n ollama deployment/ollama -c ollama -- ollama list

# 7. Test inside the cluster before testing Application Gateway
echo "[7/7] Testing inside the cluster..."
kubectl run ollama-test -n ollama \
  --rm --restart=Never \
  --image=curlimages/curl:8.10.1 -- \
  curl -u "admin:${OLLAMA_PASSWORD}" \
  http://ollama-service/api/tags

echo ""
echo "=== Deployment script completed successfully ==="
echo ""
echo "To test through Application Gateway, run:"
echo "curl -u \"admin:${OLLAMA_PASSWORD}\" https://ollama.example.com/api/tags"
echo ""
echo "If Application Gateway returns 502/504, run:"
echo "  az network application-gateway show-backend-health --resource-group <RESOURCE_GROUP> --name <APPLICATION_GATEWAY_NAME> -o json"