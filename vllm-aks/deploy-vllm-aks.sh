#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Usage: [MODEL=<key>] ./deploy-vllm-aks.sh [models]
if [ "${1:-}" = "models" ]; then
  printf '%-20s %-9s %-6s %s\n' KEY VRAM GATED NOTES
  grep -v '^#' "${SCRIPT_DIR}/models.conf" | awk -F'|' 'NF>=6 {printf "%-20s %-9s %-6s %s\n", $1, $5, $4, $6}'
  echo; echo "Use: MODEL=<key> bash $0      (gated = needs HF_TOKEN and an accepted license)"
  exit 0
fi

for cmd in kubectl helm openssl envsubst; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found."; exit 1; }
done

# ---- Configuration (override via environment) -------------------------------
: "${VLLM_HOST:?Set VLLM_HOST (DNS name pointing at the Application Gateway IP)}"
: "${GPU_POOL_NAME:?Set GPU_POOL_NAME (AKS GPU node pool name)}"
export VLLM_HOST GPU_POOL_NAME
MODEL_KEY="${MODEL:-llama-3.1-8b}"
CATALOG_LINE="$(grep -v '^#' "${SCRIPT_DIR}/models.conf" | awk -F'|' -v k="${MODEL_KEY}" '$1==k {print; exit}')"
if [ -z "${CATALOG_LINE}" ] && [ -z "${MODEL_NAME:-}" ]; then
  echo "ERROR: unknown MODEL '${MODEL_KEY}'. Available models:"; bash "$0" models | sed 's/^/  /'; exit 1
fi
IFS='|' read -r _KEY CAT_MODEL CAT_MAXLEN CAT_GATED _VRAM _NOTE <<<"${CATALOG_LINE:-|||||}"
export MODEL_NAME="${MODEL_NAME:-${CAT_MODEL}}"
MODEL_GATED="${CAT_GATED:-yes}"          # unknown (custom) models: assume gated, only blocks if no HF token
export VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:v0.10.2}"   # pin; change as needed
export DTYPE="${DTYPE:-auto}"                                  # use "half" on T4
export MAX_MODEL_LEN="${MAX_MODEL_LEN:-${CAT_MAXLEN:-8192}}"      # use 4096 on 16GB GPUs
HF_TOKEN="${HF_TOKEN:-}"
ENABLE_MONITORING="${ENABLE_MONITORING:-true}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-$(openssl rand -base64 18)}"

ENABLE_WEBUI="${ENABLE_WEBUI:-false}"
export WEBUI_HOST="${WEBUI_HOST:-}"
export WEBUI_IMAGE="${WEBUI_IMAGE:-ghcr.io/open-webui/open-webui:main}"
export INGRESS_CLASS=azure-application-gateway STORAGE_CLASS=managed-csi-premium
if [ "${ENABLE_WEBUI}" = "true" ] && [ -z "${WEBUI_HOST}" ]; then
  echo "ERROR: ENABLE_WEBUI=true requires WEBUI_HOST (a second DNS name pointing at the same gateway)."; exit 1
fi

VARS='${VLLM_HOST} ${MODEL_NAME} ${VLLM_IMAGE} ${GPU_POOL_NAME} ${DTYPE} ${MAX_MODEL_LEN}'

# Render a manifest with envsubst and refuse to deploy if any ${PLACEHOLDER} is left unresolved.
render() {
  local out
  out="$(envsubst "$1" < "$2")"
  if grep -Eq '\$\{[A-Za-z_]+\}' <<<"${out}"; then
    echo "ERROR: unresolved placeholders in $2:" >&2
    grep -Eo '\$\{[A-Za-z_]+\}' <<<"${out}" | sort -u >&2
    exit 1
  fi
  printf '%s\n' "${out}"
}

echo "=== vLLM on AKS + Application Gateway: model=${MODEL_NAME} max-len=${MAX_MODEL_LEN} ==="

# 1. Prerequisites (warn only)
echo "[1/8] Checking cluster prerequisites..."
kubectl get nodes -l "kubernetes.azure.com/agentpool=${GPU_POOL_NAME}" -o wide \
  || echo "WARNING: no nodes in pool ${GPU_POOL_NAME}"
kubectl get nodes -l "kubernetes.azure.com/agentpool=${GPU_POOL_NAME}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  gpu="}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' \
  || true
kubectl get sc managed-csi-premium >/dev/null || echo "WARNING: managed-csi-premium not found."
kubectl get pods -n kube-system | grep -i ingress-appgw >/dev/null \
  || echo "WARNING: AGIC not found. Enable: az aks enable-addons -a ingress-appgw -g <rg> -n <aks> --appgw-id <id>"

# 2. Namespace + secrets
echo "[2/8] Creating namespace and secrets..."
kubectl create namespace vllm --dry-run=client -o yaml | kubectl apply -f -

# Reuse existing API key if present so re-runs don't rotate it
if [ -z "${VLLM_API_KEY:-}" ]; then
  VLLM_API_KEY="$(kubectl get secret vllm-api-key -n vllm -o jsonpath='{.data.api-key}' 2>/dev/null | base64 -d || true)"
  if [ -z "${VLLM_API_KEY}" ]; then
    VLLM_API_KEY="$(openssl rand -hex 32)"
    GENERATED_KEY=1
  fi
fi
kubectl create secret generic vllm-api-key -n vllm \
  --from-literal=api-key="${VLLM_API_KEY}" --dry-run=client -o yaml | kubectl apply -f -
if ! kubectl get secret webui-secret -n vllm >/dev/null 2>&1; then
  kubectl create secret generic webui-secret -n vllm --from-literal=secret-key="$(openssl rand -hex 32)"
fi

if [ -n "${HF_TOKEN}" ]; then
  kubectl create secret generic hf-token -n vllm \
    --from-literal=token="${HF_TOKEN}" --dry-run=client -o yaml | kubectl apply -f -
elif [ "${MODEL_GATED}" = "yes" ] && ! kubectl get secret hf-token -n vllm >/dev/null 2>&1; then
  echo "ERROR: ${MODEL_NAME} is a gated model; set HF_TOKEN (and accept its license on huggingface.co),"
  echo "       or pick an ungated model: bash $0 models"
  exit 1
fi

# 3. Monitoring
if [ "${ENABLE_MONITORING}" = "true" ]; then
  echo "[3/8] Deploying monitoring stack..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update >/dev/null
  helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
    --namespace monitoring --create-namespace \
    --set grafana.adminPassword="${GRAFANA_PASSWORD}" \
    --set prometheus.prometheusSpec.retention=7d \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=managed-csi-premium \
    --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=50Gi \
    --set alertmanager.enabled=false \
    --wait --timeout 10m
  RENDERED="$(render "${VARS}" "${SCRIPT_DIR}/vllm-monitoring-aks.yaml")"
  kubectl apply -f - <<<"${RENDERED}"
else
  echo "[3/8] Monitoring skipped (ENABLE_MONITORING=false)."
fi

# 4. Deploy vLLM
echo "[4/8] Deploying vLLM (model: ${MODEL_NAME}, host: ${VLLM_HOST})..."
RENDERED="$(render "${VARS}" "${SCRIPT_DIR}/vllm-aks-appgw.yaml")"
kubectl apply -f - <<<"${RENDERED}"

# 5. Wait
echo "[5/8] Waiting up to 20 min for rollout (model download + load)..."
if ! kubectl rollout status deployment/vllm -n vllm --timeout=1200s; then
  echo "ERROR: rollout failed. Diagnostics:"
  kubectl get pods -n vllm -o wide
  kubectl describe pod -n vllm -l app=vllm | tail -40
  kubectl logs -n vllm deployment/vllm --tail=50 || true
  exit 1
fi
kubectl get pvc,pods,svc,ingress -n vllm

# 6. In-cluster tests
echo "[6/8] Testing /v1/models in-cluster..."
kubectl run vllm-test -n vllm -i --rm --quiet --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -sS -H "Authorization: Bearer ${VLLM_API_KEY}" http://vllm-service/v1/models
echo

echo "[7/8] Testing chat completion in-cluster..."
kubectl run vllm-test-chat -n vllm -i --rm --quiet --restart=Never \
  --image=curlimages/curl:8.10.1 --command -- \
  curl -sS -H "Content-Type: application/json" -H "Authorization: Bearer ${VLLM_API_KEY}" \
  -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello\"}],\"max_tokens\":16}" \
  http://vllm-service/v1/chat/completions
echo

# 8. Open WebUI (optional)
if [ "${ENABLE_WEBUI}" = "true" ]; then
  echo "[8/8] Deploying Open WebUI at ${WEBUI_HOST}..."
  RENDERED="$(render '${WEBUI_HOST} ${WEBUI_IMAGE} ${INGRESS_CLASS} ${STORAGE_CLASS}' "${SCRIPT_DIR}/open-webui.yaml")"
  kubectl apply -f - <<<"${RENDERED}"
  kubectl rollout status deployment/open-webui -n vllm --timeout=600s \
    || echo "WARNING: Open WebUI not ready yet; check: kubectl logs -n vllm deployment/open-webui"
else
  echo "[8/8] Open WebUI skipped (set ENABLE_WEBUI=true WEBUI_HOST=chat.yourdomain.com to enable)."
fi

echo "=== Done ==="
if [ "${GENERATED_KEY:-0}" = "1" ]; then
  echo "Generated API key (shown once, store it): ${VLLM_API_KEY}"
fi
echo "API through Application Gateway:"
echo "  curl -H \"Authorization: Bearer <API_KEY>\" http://${VLLM_HOST}/v1/models"
[ "${ENABLE_WEBUI}" = "true" ] && echo "Chat UI: http://${WEBUI_HOST}/  (first account created becomes admin)"
echo "If you get 502/504:"
echo "  az network application-gateway show-backend-health -g <RG> -n <APPGW> -o json"
if [ "${ENABLE_MONITORING}" = "true" ]; then
  echo "Grafana: kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring  (user: admin)"
  echo "  password: kubectl get secret prometheus-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d"
fi
