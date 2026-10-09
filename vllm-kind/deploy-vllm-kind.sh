#!/usr/bin/env bash
# vLLM stack on a kind cluster (built for an EC2 t2.large: 2 vCPU / 8 GB, no GPU).
# Usage: [MODEL=<key>] ./deploy-vllm-kind.sh [up|models|status|key|destroy]
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CMD="${1:-up}"
CLUSTER_NAME="${CLUSTER_NAME:-vllm-kind}"
INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-controller-v1.11.2}"

need() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c not found."; exit 1; }; done; }

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

# Context window (tokens) per model. Chosen to keep the KV cache around 1 GB or less on an 8 GB host;
# models without grouped-query attention (smollm2, phi) need a smaller window. Override for all: CTX_SIZE=8192
ctx_for() {
  [ -n "${CTX_SIZE:-}" ] && { echo "${CTX_SIZE}"; return; }
  case "$1" in
    qwen2.5-0.5b|qwen2.5-1.5b|llama-3.2-1b) echo 16384 ;;
    gemma-2-2b|llama-3.2-3b)                 echo 8192 ;;
    smollm2-1.7b)                            echo 4096 ;;
    phi-3.5-mini)                            echo 3072 ;;
    *)                                       echo 4096 ;;
  esac
}

case "${CMD}" in
  status)
    need kubectl
    kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
    kubectl get pods,svc,ingress,pvc -n vllm
    exit 0 ;;
  key)
    need kubectl
    kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
    kubectl get secret vllm-api-key -n vllm -o jsonpath='{.data.api-key}' | base64 -d; echo
    exit 0 ;;
  destroy)
    need kind
    kind delete cluster --name "${CLUSTER_NAME}"
    exit 0 ;;
  models)
    printf '%-14s %-8s %s\n' KEY SIZE NOTES
    grep -v '^#' "${SCRIPT_DIR}/models.conf" | awk -F'|' 'NF>=6 {printf "%-14s %-8s %s\n", $1, $5, $6}'
    echo; echo "Use: MODEL=<key> bash $0"
    exit 0 ;;
  up) ;;
  *) echo "Usage: $0 [up|models|status|key|destroy]"; exit 1 ;;
esac

need docker kind kubectl envsubst curl openssl

# ---- Configuration (override via environment) -------------------------------
MODEL_KEY="${MODEL:-qwen2.5-0.5b}"
CATALOG_LINE="$(grep -v '^#' "${SCRIPT_DIR}/models.conf" | awk -F'|' -v k="${MODEL_KEY}" '$1==k {print; exit}')"
if [ -z "${CATALOG_LINE}" ]; then
  echo "ERROR: unknown MODEL '${MODEL_KEY}'. Available models:"
  bash "$0" models | sed 's/^/  /'
  exit 1
fi
IFS='|' read -r _KEY LLAMA_HF_REPO LLAMA_HF_FILE CAT_VLLM_MODEL MODEL_SIZE MODEL_NOTE <<<"${CATALOG_LINE}"
export LLAMA_HF_REPO LLAMA_HF_FILE MODEL_ALIAS="${MODEL_KEY}"
export MODEL_NAME="${MODEL_NAME:-${CAT_VLLM_MODEL}}"      # vLLM backend model id (override with MODEL_NAME)
# Verify this tag/repo in the vLLM CPU install docs before using the vllm backend:
export VLLM_IMAGE="${VLLM_IMAGE:-public.ecr.aws/q9t5s3a7/vllm-cpu-release-repo:v0.10.2}"
export LLAMA_IMAGE="${LLAMA_IMAGE:-ghcr.io/ggml-org/llama.cpp:server}"
export LLAMA_SWAP_IMAGE="${LLAMA_SWAP_IMAGE:-ghcr.io/mostlygeek/llama-swap:cpu}"
MULTI_MODEL="${MULTI_MODEL:-true}"         # llama.cpp backend: serve ALL catalog models via llama-swap
MODELS="${MODELS:-all}"                    # "all" or a comma list of catalog keys (multi-model mode)
export WEBUI_IMAGE="${WEBUI_IMAGE:-ghcr.io/open-webui/open-webui:main}"
export INGRESS_CLASS=nginx STORAGE_CLASS=standard
BACKEND="${BACKEND:-auto}"                 # auto | vllm | llamacpp
ENABLE_WEBUI="${ENABLE_WEBUI:-true}"
HF_TOKEN="${HF_TOKEN:-}"

# ---- Hostnames: nip.io on the EC2 public IP, else localtest.me --------------
detect_public_ip() {
  local tok
  tok="$(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token \
        -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' || true)"
  [ -n "${tok}" ] && curl -s -m 2 -H "X-aws-ec2-metadata-token: ${tok}" \
        http://169.254.169.254/latest/meta-data/public-ipv4 || true
}
if [ -z "${VLLM_HOST:-}" ]; then
  PUBLIC_IP="${PUBLIC_IP:-$(detect_public_ip)}"
  if [ -n "${PUBLIC_IP}" ]; then
    VLLM_HOST="api.${PUBLIC_IP}.nip.io"; WEBUI_HOST="${WEBUI_HOST:-chat.${PUBLIC_IP}.nip.io}"
  else
    VLLM_HOST="vllm.localtest.me";       WEBUI_HOST="${WEBUI_HOST:-chat.localtest.me}"
  fi
fi
export VLLM_HOST WEBUI_HOST="${WEBUI_HOST:-chat.localtest.me}"

# ---- Backend selection ------------------------------------------------------
if [ "${BACKEND}" = "auto" ]; then
  if grep -qi avx512 /proc/cpuinfo; then BACKEND=vllm; else BACKEND=llamacpp; fi
fi
if [ "${BACKEND}" = "vllm" ] && ! grep -qi avx512 /proc/cpuinfo; then
  echo "WARNING: no AVX512 on this CPU; the vLLM CPU image will likely crash (illegal instruction)."
fi
if [ "${BACKEND}" = "vllm" ]; then
  MANIFEST="${SCRIPT_DIR}/vllm-kind.yaml"; VARS='${VLLM_HOST} ${MODEL_NAME} ${VLLM_IMAGE}'
  TEST_MODEL="${MODEL_NAME}"
else
  if [ "${MULTI_MODEL}" = "true" ]; then
    MANIFEST="${SCRIPT_DIR}/vllm-kind-multi.yaml"
    VARS='${VLLM_HOST} ${LLAMA_SWAP_IMAGE} ${CONFIG_SHA}'
    # >>> multi-select
    SELECTED_KEYS=(); MODELS_LIST=""
    while IFS='|' read -r k repo file _v _sz _nt; do
      [ -z "${k}" ] && continue
      if [ "${MODELS}" = "all" ] || [[ ",${MODELS}," == *",${k},"* ]]; then
        SELECTED_KEYS+=("${k}"); MODELS_LIST+="${k}|${repo}|${file}"$'\n'
      fi
    done < <(grep -v '^#' "${SCRIPT_DIR}/models.conf")
    if [ "${MODELS}" != "all" ]; then
      IFS=',' read -ra _REQ <<<"${MODELS}"
      for _r in "${_REQ[@]}"; do
        [[ " ${SELECTED_KEYS[*]} " == *" ${_r} "* ]] || { echo "ERROR: unknown key '${_r}' in MODELS. Run: bash $0 models"; exit 1; }
      done
    fi
    [ "${#SELECTED_KEYS[@]}" -gt 0 ] || { echo "ERROR: no models selected."; exit 1; }
    TEST_MODEL="${MODEL_KEY}"
    [[ " ${SELECTED_KEYS[*]} " == *" ${TEST_MODEL} "* ]] || TEST_MODEL="${SELECTED_KEYS[0]}"
    # <<< multi-select
  else
    MANIFEST="${SCRIPT_DIR}/vllm-kind-llamacpp.yaml"
    export LLAMA_CTX="$(ctx_for "${MODEL_KEY}")"
    VARS='${VLLM_HOST} ${LLAMA_IMAGE} ${LLAMA_HF_REPO} ${LLAMA_HF_FILE} ${MODEL_ALIAS} ${LLAMA_CTX}'
    TEST_MODEL="${MODEL_ALIAS}"
  fi
fi

MEM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
[ "${MEM_MB}" -gt 0 ] && [ "${MEM_MB}" -lt 6500 ] && echo "WARNING: only ${MEM_MB} MB RAM; expect OOM kills."
if [ "${BACKEND}" = "llamacpp" ] && [ "${MULTI_MODEL}" = "true" ]; then
  MODEL_DESC="${#SELECTED_KEYS[@]} models via llama-swap"
  AVAIL_GB="$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc 0-9)"
  [ "${MODELS}" = "all" ] && [ -n "${AVAIL_GB}" ] && [ "${AVAIL_GB}" -lt 25 ] && echo "WARNING: only ${AVAIL_GB} GB free; downloading all models needs about 25 GB. Use MODELS=qwen2.5-0.5b,qwen2.5-1.5b to pick fewer."
else
  MODEL_DESC="${MODEL_KEY} (${MODEL_SIZE})"
fi
echo "=== kind deploy: model=${MODEL_DESC} backend=${BACKEND} api=${VLLM_HOST} webui=${ENABLE_WEBUI}:${WEBUI_HOST} ==="

# 1. Cluster
echo "[1/7] Creating kind cluster (if missing)..."
if ! kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  kind create cluster --name "${CLUSTER_NAME}" --config "${SCRIPT_DIR}/kind-config.yaml"
fi
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

# 2. ingress-nginx
echo "[2/7] Installing ingress-nginx ${INGRESS_NGINX_VERSION}..."
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=300s

# 3. Secrets
echo "[3/7] Creating secrets..."
kubectl create namespace vllm --dry-run=client -o yaml | kubectl apply -f -
VLLM_API_KEY="${VLLM_API_KEY:-$(kubectl get secret vllm-api-key -n vllm -o jsonpath='{.data.api-key}' 2>/dev/null | base64 -d || true)}"
VLLM_API_KEY="${VLLM_API_KEY:-$(openssl rand -hex 16)}"
kubectl create secret generic vllm-api-key -n vllm \
  --from-literal=api-key="${VLLM_API_KEY}" --dry-run=client -o yaml | kubectl apply -f -
if ! kubectl get secret webui-secret -n vllm >/dev/null 2>&1; then
  kubectl create secret generic webui-secret -n vllm --from-literal=secret-key="$(openssl rand -hex 32)"
fi
if [ -n "${HF_TOKEN}" ]; then
  kubectl create secret generic hf-token -n vllm \
    --from-literal=token="${HF_TOKEN}" --dry-run=client -o yaml | kubectl apply -f -
fi

# 4. Model server
ROLLOUT_TIMEOUT=900
if [ "${BACKEND}" = "llamacpp" ] && [ "${MULTI_MODEL}" = "true" ]; then
  ROLLOUT_TIMEOUT=2700
  TMPD="$(mktemp -d)"; trap 'rm -rf "${TMPD}"' EXIT
  # >>> multi-config
  printf '%s' "${MODELS_LIST}" > "${TMPD}/models.list"
  {
    echo "healthCheckTimeout: 300"
    [ -n "${SWAP_LOG_LEVEL:-}" ] && echo "logLevel: ${SWAP_LOG_LEVEL}"
    echo "startPort: 9000"
    echo "models:"
    for k in "${SELECTED_KEYS[@]}"; do
      f="$(awk -F'|' -v k="${k}" '$1==k {print $3}' "${TMPD}/models.list")"
      echo "  \"${k}\":"
      echo "    cmd: /app/llama-server --port \${PORT} -m /models/${f} --alias ${k} --ctx-size $(ctx_for "${k}") --api-key ${VLLM_API_KEY}"
      echo "    ttl: 900"
    done
  } > "${TMPD}/config.yaml"
  # <<< multi-config
  export CONFIG_SHA="$(cat "${TMPD}/models.list" "${TMPD}/config.yaml" | sha256sum | cut -c1-16)"
  kubectl create configmap llama-models -n vllm \
    --from-file=models.list="${TMPD}/models.list" --from-file=fetch.sh="${SCRIPT_DIR}/fetch-models.sh" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic llama-swap-config -n vllm \
    --from-file=config.yaml="${TMPD}/config.yaml" --dry-run=client -o yaml | kubectl apply -f -
  echo "Models to serve: ${SELECTED_KEYS[*]}"
  echo "First run downloads them (several GB). Follow with: kubectl logs -n vllm deployment/vllm -c fetch-models -f"
fi
echo "[4/7] Deploying model server..."
PVC_CUR="$(kubectl get pvc vllm-model-cache -n vllm -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || true)"
if [ -n "${PVC_CUR}" ] && [ "${PVC_CUR}" != "15Gi" ]; then
  echo "ERROR: existing model-cache PVC is ${PVC_CUR} (this version needs 15Gi so several models fit)."
  echo "       Run: bash $0 destroy   then run this script again."
  exit 1
fi
RENDERED="$(render "${VARS}" "${MANIFEST}")"
kubectl apply -f - <<<"${RENDERED}"
echo "[5/7] Waiting for model server (image + model download can take several minutes)..."
if ! kubectl rollout status deployment/vllm -n vllm --timeout=${ROLLOUT_TIMEOUT}s; then
  kubectl get pods -n vllm -o wide
  kubectl describe pod -n vllm -l app=vllm | tail -30
  kubectl logs -n vllm deployment/vllm --all-containers --tail=50 || true
  exit 1
fi

# 6. Open WebUI
if [ "${ENABLE_WEBUI}" = "true" ]; then
  echo "[6/7] Deploying Open WebUI..."
  RENDERED="$(render '${WEBUI_HOST} ${WEBUI_IMAGE} ${INGRESS_CLASS} ${STORAGE_CLASS}' "${SCRIPT_DIR}/open-webui.yaml")"
  kubectl apply -f - <<<"${RENDERED}"
  kubectl rollout status deployment/open-webui -n vllm --timeout=600s \
    || echo "WARNING: Open WebUI not ready yet; check: kubectl logs -n vllm deployment/open-webui"
else
  echo "[6/7] Open WebUI skipped."
fi

# 7. Test through the ingress (Host header works even without DNS)
echo "[7/7] Testing through ingress..."
curl -sS -H "Host: ${VLLM_HOST}" -H "Authorization: Bearer ${VLLM_API_KEY}" http://localhost/v1/models
echo
curl -sS --max-time 600 -H "Host: ${VLLM_HOST}" -H "Authorization: Bearer ${VLLM_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${TEST_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello\"}],\"max_tokens\":16}" \
  http://localhost/v1/chat/completions
echo

cat <<INFO

=== Done ===
Models  : $( [ "${BACKEND}" = "llamacpp" ] && [ "${MULTI_MODEL}" = "true" ] && echo "${SELECTED_KEYS[*]}  (all appear in the chat UI dropdown; the one you pick is loaded on demand)" || echo "${TEST_MODEL}   (switch: MODEL=<key> bash $0 ; list: bash $0 models)" )
API URL : http://${VLLM_HOST}/v1
API key : ${VLLM_API_KEY}
$( [ "${ENABLE_WEBUI}" = "true" ] && echo "Chat UI : http://${WEBUI_HOST}/   (first account you create becomes admin)" )

Outside access: open TCP 80 in the EC2 security group (your IP only), or use an SSH tunnel:
  ssh -L 8080:localhost:80 <user>@<EC2_IP>   then browse http://${WEBUI_HOST}:8080/
Other commands: $0 status | key | destroy
INFO
