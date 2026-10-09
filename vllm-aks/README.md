# vLLM on AKS with Application Gateway (GPU)

Deploys an OpenAI-compatible vLLM server on an AKS GPU node pool behind Application Gateway (AGIC), with API-key auth, optional Open WebUI chat UI, and optional Prometheus/Grafana/DCGM monitoring.

## Files

| File | Purpose |
|------|---------|
| `models.conf` | Model catalog (8 models). Add a line to add a model |
| `models-extra.conf` | 10 more models, ready to paste into `models.conf` |
| `install-prereqs.sh` | Installs az, kubectl, helm, envsubst, curl, openssl (Ubuntu/Debian) |
| `deploy-vllm-aks.sh` | Main script (secrets, monitoring, vLLM, tests, optional UI) |
| `vllm-aks-appgw.yaml` | Namespace, PVC, Deployment, Service, AGIC Ingress |
| `vllm-monitoring-aks.yaml` | DCGM GPU exporter + ServiceMonitors for kube-prometheus-stack |
| `open-webui.yaml` | Optional browser chat UI |

Always deploy through the script. The YAMLs contain `${...}` placeholders filled in by `envsubst`; the script aborts if any placeholder is left unresolved. Auth is vLLM's own `--api-key`: clients send `Authorization: Bearer <key>` on `/v1/*`. `/health` and `/metrics` are unauthenticated, so probes and Prometheus work (and the Application Gateway health probe passes).

## 1. Prerequisites

Local tools: `az`, `kubectl`, `helm`, `openssl`, `envsubst`. On Ubuntu/Debian install them all with:
```bash
bash install-prereqs.sh
az login
az account set --subscription <SUBSCRIPTION_ID>
```
On macOS: `brew install azure-cli kubectl helm gettext && brew link --force gettext`.

```bash
# GPU node pool. A10 24 GB shown; a 16 GB T4 needs DTYPE=half MAX_MODEL_LEN=4096.
# Use a large OS disk: GPU images are several GB.
az aks nodepool add -g <RG> --cluster-name <AKS> -n gpupool \
  --node-vm-size Standard_NV36ads_A10_v5 --node-count 1 \
  --node-osdisk-size 200 \
  --node-taints sku=gpu:NoSchedule

# Application Gateway ingress controller
az aks enable-addons -a ingress-appgw -g <RG> -n <AKS> --appgw-id <APPGW_RESOURCE_ID>

az aks get-credentials -g <RG> -n <AKS>
```

Check before running the script:
- **GPU quota** in your subscription and region (often 0 by default). Request an increase if needed.
- GPUs are schedulable: `kubectl get nodes -o custom-columns=N:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu` shows a number. If empty, install the NVIDIA device plugin or GPU Operator (see Azure's "use GPUs on AKS" docs).
- **DNS**: A records for `VLLM_HOST` (and `WEBUI_HOST` if using the UI) pointing at the Application Gateway public IP.
- **Hugging Face**: for Llama, accept the model license on huggingface.co and create `HF_TOKEN`. Without it the pod crash-loops on download.

## 2. Run

```bash
unzip vllm-aks.zip && cd vllm-aks
export VLLM_HOST=vllm.yourdomain.com
export GPU_POOL_NAME=gpupool
export HF_TOKEN=hf_xxx
# optional:
# export ENABLE_WEBUI=true WEBUI_HOST=chat.yourdomain.com
# export ENABLE_MONITORING=false
# export DTYPE=half MAX_MODEL_LEN=4096        # 16 GB GPUs
bash deploy-vllm-aks.sh
```

The script prints a generated API key **once**. It reuses the existing key on re-runs, so re-running does not rotate it. First start can take 10 to 20 minutes (image pull, model download, load). Watch with `kubectl get pods -n vllm -w` and `kubectl logs -n vllm deployment/vllm -f`.

## Models included (pick one with `MODEL=<key>`)

Weights are not in the zip; vLLM downloads them from Hugging Face on first start and caches them on the 100 Gi volume.

| Key | Hugging Face model | Gated | ~GPU memory (fp16) | Notes |
|-----|--------------------|-------|--------------------|-------|
| `qwen2.5-0.5b` | Qwen/Qwen2.5-0.5B-Instruct | no | ~1 GB | Smallest; fits any GPU |
| `qwen2.5-1.5b` | Qwen/Qwen2.5-1.5B-Instruct | no | ~3 GB | |
| `smollm2-1.7b` | HuggingFaceTB/SmolLM2-1.7B-Instruct | no | ~4 GB | Apache-2.0 |
| `tinyllama-1.1b` | TinyLlama/TinyLlama-1.1B-Chat-v1.0 | no | ~2.5 GB | 2k context |
| `phi-3.5-mini` | microsoft/Phi-3.5-mini-instruct | no | ~8 GB | 3.8B, MIT license |
| `llama-3.2-1b` | meta-llama/Llama-3.2-1B-Instruct | **yes** | ~2.5 GB | Needs `HF_TOKEN` + accepted Meta license |
| `llama-3.2-3b` | meta-llama/Llama-3.2-3B-Instruct | **yes** | ~7 GB | Needs `HF_TOKEN` + accepted Meta license |
| `llama-3.1-8b` (default) | meta-llama/Llama-3.1-8B-Instruct | **yes** | ~16 GB | Needs an A10 (24 GB) or larger; too tight for a 16 GB T4 |

Five of the eight are ungated, so they work without an `HF_TOKEN`. The memory figures are rough fp16 weight sizes; the KV cache needs more on top, so lower `MAX_MODEL_LEN` if a model does not fit.

```bash
bash deploy-vllm-aks.sh models                                       # list the catalog
MODEL=qwen2.5-1.5b VLLM_HOST=... GPU_POOL_NAME=... bash deploy-vllm-aks.sh
MODEL_NAME=org/some-model MAX_MODEL_LEN=4096 ... bash deploy-vllm-aks.sh   # any other Hugging Face model
```
To add more models, copy lines from `models-extra.conf` into `models.conf` (format `key|HF model id|max-model-len|gated|VRAM|notes`). vLLM serves one model per deployment. Re-running the script with a different `MODEL` replaces the running model (the pod restarts and downloads the new one). The script refuses to start a gated model without an `HF_TOKEN`. On a 16 GB T4, use `DTYPE=half`.

## 3. Use it

```bash
curl -H "Authorization: Bearer <KEY>" http://vllm.yourdomain.com/v1/models
curl -H "Authorization: Bearer <KEY>" -H "Content-Type: application/json" \
  -d '{"model":"meta-llama/Llama-3.1-8B-Instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":32}' \
  http://vllm.yourdomain.com/v1/chat/completions
```

```python
from openai import OpenAI
c = OpenAI(base_url="http://vllm.yourdomain.com/v1", api_key="<KEY>")
print(c.chat.completions.create(model="meta-llama/Llama-3.1-8B-Instruct",
      messages=[{"role": "user", "content": "Hi"}]).choices[0].message.content)
```

Retrieve the key later:
```bash
kubectl get secret vllm-api-key -n vllm -o jsonpath='{.data.api-key}' | base64 -d; echo
```

**Open WebUI** (`ENABLE_WEBUI=true`): browse `http://<WEBUI_HOST>/`, create the first account (it becomes admin), then disable new sign-ups: Admin Panel > Settings > General > **Enable New Sign Ups**.

**Grafana** (monitoring enabled):
```bash
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring     # http://localhost:3000, user admin
kubectl get secret prometheus-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d
```
Import dashboard ID **12239** (NVIDIA DCGM). vLLM metrics are scraped from `/metrics`. Skip the DCGM DaemonSet if you installed the NVIDIA GPU Operator (it ships its own exporter).

## Options (environment variables)

| Variable | Default | Notes |
|----------|---------|-------|
| `VLLM_HOST` | required | DNS name for the API |
| `GPU_POOL_NAME` | required | Matches nodeSelector `kubernetes.azure.com/agentpool` |
| `MODEL` | `llama-3.1-8b` | Catalog key; see `models.conf` |
| `MODEL_NAME` | from catalog | Override with any Hugging Face model id |
| `VLLM_IMAGE` | `vllm/vllm-openai:v0.10.2` | Pin the version you want |
| `DTYPE` / `MAX_MODEL_LEN` | `auto` / from catalog | Lower for small GPUs (T4: `half` / `4096`) |
| `HF_TOKEN` | empty | Required for gated models |
| `ENABLE_WEBUI` / `WEBUI_HOST` | `false` / empty | Host required when enabled |
| `WEBUI_IMAGE` | `ghcr.io/open-webui/open-webui:main` | |
| `ENABLE_MONITORING` | `true` | Prometheus, Grafana, DCGM |
| `GRAFANA_PASSWORD` | random | |

## HTTPS

Manifests use HTTP by default. Either add a Key Vault certificate on the Application Gateway listener, or create a TLS secret and uncomment the `tls:` block and the `ssl-redirect` annotation in `vllm-aks-appgw.yaml`. Do this before exposing the API publicly; otherwise the API key travels in clear text.

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Pod `Pending` | `kubectl describe pod -n vllm -l app=vllm`: GPU not allocatable, taint/nodeSelector mismatch (`GPU_POOL_NAME`), quota, or PVC not bound (`kubectl get pvc -n vllm`) |
| `ErrImagePull` / `no space left on device` | Larger node OS disk; GPU images are several GB |
| `ERROR: ... is a gated model` | Set `HF_TOKEN` and accept the license on huggingface.co, or choose an ungated model (`bash deploy-vllm-aks.sh models`) |
| Pod `CrashLoopBackOff` | `kubectl logs -n vllm deployment/vllm --previous`. Common: missing/invalid `HF_TOKEN` or license not accepted, model too big for the GPU (lower `MAX_MODEL_LEN`, use `DTYPE=half` on T4), wrong dtype |
| `OOMKilled` or CUDA out of memory | Smaller `MAX_MODEL_LEN`, larger GPU, or a quantized/smaller model |
| `InvalidImageName` showing `${...}` | Manifest applied without the script; re-run the script |
| Application Gateway 502/504 | `az network application-gateway show-backend-health -g <RG> -n <APPGW> -o json`; the probe path is `/health` (set by annotation) |
| Long generations cut off | Gateway request timeout is set to 300s via annotation; raise `appgw.ingress.kubernetes.io/request-timeout` if needed |
| A non-admin Open WebUI user sees no models | Open WebUI hides models from non-admins until access is granted. This zip sets `BYPASS_MODEL_ACCESS_CONTROL=true` on a fresh install. On an existing install run `kubectl set env deployment/open-webui -n vllm BYPASS_MODEL_ACCESS_CONTROL=true`, or grant access per model in Admin Panel > Settings > Models |
| 401 on `/v1/*` | Missing or wrong `Authorization: Bearer <key>` |
| ServiceMonitors not scraped | Prometheus installed by the script with `release=prometheus`; ensure the release name is `prometheus` |

## Security notes

- Plain HTTP by default: add TLS before public use. Restrict access with NSG or Application Gateway WAF/IP rules where possible.
- Disable Open WebUI sign-ups after creating the admin account.
- Rotate the API key: `kubectl delete secret vllm-api-key -n vllm`, re-run the script, then `kubectl rollout restart deployment/vllm deployment/open-webui -n vllm`.
- Cleanup: `kubectl delete namespace vllm` (and `monitoring` if you installed it); delete the GPU node pool when idle to stop GPU billing: `az aks nodepool delete -g <RG> --cluster-name <AKS> -n gpupool`.
