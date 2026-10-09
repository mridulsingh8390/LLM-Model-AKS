#!/usr/bin/env bash
# Installs prerequisites for deploy-vllm-kind.sh: docker, kind, kubectl, envsubst, curl, openssl.
# Supports Ubuntu/Debian (apt) and Amazon Linux / RHEL-family (dnf/yum). Safe to re-run.
set -euo pipefail

KIND_VERSION="${KIND_VERSION:-v0.24.0}"
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

if command -v apt-get >/dev/null 2>&1; then
  PM=apt
elif command -v dnf >/dev/null 2>&1; then
  PM=dnf
elif command -v yum >/dev/null 2>&1; then
  PM=yum
else
  echo "ERROR: unsupported OS (need apt, dnf or yum)."; exit 1
fi
echo "=== Installing prerequisites using ${PM} ==="

case "${PM}" in
  apt)
    ${SUDO} apt-get update -y
    command -v docker >/dev/null 2>&1 || ${SUDO} apt-get install -y docker.io
    ${SUDO} apt-get install -y gettext-base curl openssl ca-certificates ;;
  dnf|yum)
    command -v docker >/dev/null 2>&1 || ${SUDO} ${PM} install -y docker
    ${SUDO} ${PM} install -y gettext openssl ca-certificates
    command -v curl >/dev/null 2>&1 || ${SUDO} ${PM} install -y curl ;;
esac

${SUDO} systemctl enable --now docker
echo "Checking that Docker works..."
${SUDO} docker run --rm hello-world >/dev/null && echo "OK   docker run hello-world"
if [ "$(id -u)" -ne 0 ]; then
  ${SUDO} usermod -aG docker "$USER"
  echo "NOTE: log out and back in (or run 'newgrp docker') so docker works without sudo."
fi

ARCH="$(uname -m)"; case "${ARCH}" in x86_64) A=amd64;; aarch64|arm64) A=arm64;; *) echo "Unsupported arch ${ARCH}"; exit 1;; esac

if ! command -v kind >/dev/null 2>&1; then
  echo "Installing kind ${KIND_VERSION}..."
  curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${A}"
  ${SUDO} install -m 0755 /tmp/kind /usr/local/bin/kind
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "Installing kubectl..."
  KVER="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KVER}/bin/linux/${A}/kubectl"
  ${SUDO} install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
fi

echo "=== Verification ==="
for c in docker kind kubectl envsubst curl openssl; do
  if command -v "$c" >/dev/null 2>&1; then echo "OK   $c"; else echo "MISSING $c"; fi
done
docker --version; kind version; kubectl version --client
echo
echo "Disk check (need 30 GB or more free):"; df -h / | tail -1
echo "Next: bash deploy-vllm-kind.sh"
