#!/usr/bin/env bash
# Installs the local tools for deploy-vllm-aks.sh: az (Azure CLI), kubectl, helm, envsubst, curl, openssl.
# Ubuntu/Debian only. On macOS use: brew install azure-cli kubectl helm gettext && brew link --force gettext
# Safe to re-run.
set -euo pipefail

SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
command -v apt-get >/dev/null 2>&1 || { echo "ERROR: this script supports Ubuntu/Debian (apt). Install az, kubectl, helm, envsubst manually."; exit 1; }

echo "=== Installing prerequisites ==="
${SUDO} apt-get update -y
${SUDO} apt-get install -y gettext-base curl openssl ca-certificates apt-transport-https lsb-release gnupg

if ! command -v az >/dev/null 2>&1; then
  echo "Installing Azure CLI..."
  curl -fsSL https://aka.ms/InstallAzureCLIDeb | ${SUDO} bash
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "Installing kubectl..."
  ARCH="$(uname -m)"; case "${ARCH}" in x86_64) A=amd64;; aarch64|arm64) A=arm64;; *) echo "Unsupported arch ${ARCH}"; exit 1;; esac
  KVER="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KVER}/bin/linux/${A}/kubectl"
  ${SUDO} install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
fi

if ! command -v helm >/dev/null 2>&1; then
  echo "Installing helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | ${SUDO} bash
fi

echo "=== Verification ==="
for c in az kubectl helm envsubst curl openssl; do
  if command -v "$c" >/dev/null 2>&1; then echo "OK   $c"; else echo "MISSING $c"; fi
done
az version --query '"azure-cli"' -o tsv 2>/dev/null || true
kubectl version --client; helm version --short

cat <<'NEXT'

Next steps:
  az login
  az account set --subscription <SUBSCRIPTION_ID>
  az aks get-credentials -g <RG> -n <AKS>
  kubectl get nodes
Then see README.md section 1 (GPU node pool, AGIC) and section 2 (run the script).
NEXT
