# vLLM stack on kind (EC2 t2.large, CPU only)

Tests the full wiring (ingress, API-key auth, model server, browser chat UI) without a GPU. It validates the setup only; the real 8B model runs on AKS.

## Files

| File | Purpose |
|------|---------|
| `models.conf` | Small-model catalog (7 models). Edit it to add your own |
| `install-prereqs.sh` | Installs docker, kind, kubectl, envsubst, curl, openssl (Ubuntu/Debian/Amazon Linux) |
| `deploy-vllm-kind.sh` | Main script. Subcommands: `up` (default), `status`, `key`, `destroy` |
| `kind-config.yaml` | kind cluster config (host port 80 mapped, `ingress-ready` label) |
| `vllm-kind.yaml` | vLLM CPU backend (needs a CPU with AVX512) |
| `vllm-kind-multi.yaml` | **Default.** llama-swap router + llama.cpp: every catalog model appears in the chat UI; the selected one is loaded on demand |
| `fetch-models.sh` | Init-container script: downloads the selected GGUF files once into the model volume |
| `vllm-kind-llamacpp.yaml` | Fallback (`MULTI_MODEL=false`): llama.cpp serving one model. Same Service/Ingress names and OpenAI-compatible API |
| `open-webui.yaml` | Browser chat UI |

The script picks the backend automatically (vLLM if AVX512 is present, otherwise llama.cpp). A t2.large normally has no AVX512, so expect llama.cpp.

Keep all files in one folder and run the script, not `kubectl apply -f` on the YAMLs. The YAMLs contain `${...}` placeholders that only the script fills in (it aborts if any remain).

## 1. EC2 requirements

- t2.large (2 vCPU / 8 GB RAM), Ubuntu, **at least 30 GB disk**. The default 8 GB root volume fills up (images are several GB) and pods fail with `no space left on device`. If you need to grow it, resize the EBS volume, then run `growpart /dev/xvda 1 && resize2fs /dev/xvda1` (adjust the device names with `lsblk`).
- Security group: TCP 22 from your IP. For browser access add **TCP 80 from your IP only** (traffic is plain HTTP).

## 2. Install tools

Automatic (Ubuntu/Debian or Amazon Linux/RHEL family; uses sudo if you are not root):
```bash
bash install-prereqs.sh
```
It installs Docker, kind v0.24.0, kubectl, `envsubst` (gettext), curl and openssl, enables Docker, then prints a verification list. Non-root users must log out and back in afterwards (or run `newgrp docker`) so Docker works without sudo.

Manual equivalent (Ubuntu, as root):
```bash
apt update -y
apt install -y docker.io gettext-base curl openssl
systemctl enable --now docker
docker run --rm hello-world        # quick check that Docker works
curl -Lo /usr/local/bin/kind https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64 && chmod +x /usr/local/bin/kind
curl -Lo /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && chmod +x /usr/local/bin/kubectl

kind version && kubectl version --client      # verify, then run: bash deploy-vllm-kind.sh
```

## 3. Run

```bash
unzip vllm-kind.zip && cd vllm-kind
bash install-prereqs.sh        # once
bash deploy-vllm-kind.sh
```

What it does: detects the EC2 public IP (hostnames `api.<IP>.nip.io` and `chat.<IP>.nip.io`; off EC2 it uses `*.localtest.me`), creates the kind cluster, installs ingress-nginx (pinned), creates secrets, deploys the model server and Open WebUI, and tests the API through the ingress. At the end it prints the URLs and the API key.

First run takes roughly 10 to 15 minutes: the kind node image, llama.cpp image (~260 MB), the model from Hugging Face, and the Open WebUI image (~1.6 GB, then 2 to 5 minutes to initialize on 2 vCPUs). Watch progress with `kubectl get pods -n vllm -w`.

## 4. Use it

**Browser chat:** open `http://chat.<EC2_PUBLIC_IP>.nip.io/`, create the first account (it becomes admin), then disable new sign-ups: Admin Panel > Settings > General > **Enable New Sign Ups**. Select `qwen2.5-0.5b` and chat.

**API:**
```bash
KEY=$(bash deploy-vllm-kind.sh key)
curl -H "Authorization: Bearer $KEY" http://api.<EC2_PUBLIC_IP>.nip.io/v1/models
curl -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5-0.5b","messages":[{"role":"user","content":"Hello"}],"max_tokens":32}' \
  http://api.<EC2_PUBLIC_IP>.nip.io/v1/chat/completions
```
The `model` value is the catalog key (e.g. `qwen2.5-1.5b`) on the llama.cpp backend and the Hugging Face id on the vLLM backend (check `/v1/models`). From the EC2 box itself you can also use `http://localhost/...` with `-H "Host: api.<IP>.nip.io"`.

**Without opening port 80 (SSH tunnel):**
```bash
ssh -L 8080:localhost:80 ubuntu@<EC2_IP>      # then browse http://chat.localtest.me:8080/
```
(Run the script with `VLLM_HOST=vllm.localtest.me WEBUI_HOST=chat.localtest.me`.)

## Models: all of them appear in the chat UI

The default mode runs **llama-swap** in front of llama.cpp. All catalog models are listed in the Open WebUI dropdown at the same time. When you pick one, llama-swap starts it and unloads the previous one, so only one model sits in RAM (this is how 7 models fit on an 8 GB instance). Models also unload after 15 minutes idle.

Model weights are not in the zip. On the first run an init container downloads the GGUF files from Hugging Face into the model volume (about 9.5 GB for all 7; skipped if already present). The GGUF files are public, so **no HF token is needed**.

| Key | Model | Download | Notes |
|-----|-------|----------|-------|
| `qwen2.5-0.5b` | Qwen2.5-0.5B-Instruct | 0.4 GB | Smallest and fastest |
| `qwen2.5-1.5b` | Qwen2.5-1.5B-Instruct | 1.1 GB | Better answers, still quick on 2 vCPU |
| `llama-3.2-1b` | Llama-3.2-1B-Instruct | 0.8 GB | Meta Llama 3.2 |
| `smollm2-1.7b` | SmolLM2-1.7B-Instruct | 1.1 GB | Apache-2.0 |
| `gemma-2-2b` | Gemma-2-2B-it | 1.7 GB | Chat template has no system role; requests that include a system prompt may fail |
| `llama-3.2-3b` | Llama-3.2-3B-Instruct | ~2 GB | Tight on 8 GB RAM with the UI running |
| `phi-3.5-mini` | Phi-3.5-mini-instruct (3.8B) | 2.4 GB | MIT license; tight on 8 GB RAM with the UI running |

```bash
bash deploy-vllm-kind.sh models                                   # list the catalog
bash deploy-vllm-kind.sh                                          # serve all 7 (default)
MODELS=qwen2.5-0.5b,qwen2.5-1.5b bash deploy-vllm-kind.sh         # serve only some (less disk and download)
MODEL=smollm2-1.7b bash deploy-vllm-kind.sh                       # which model the script's final test uses
MULTI_MODEL=false MODEL=qwen2.5-1.5b bash deploy-vllm-kind.sh     # fallback: single model, the earlier proven path
```

Context window (the "request exceeds the available context size" error): each model is started with a context limit, chosen so its KV cache stays around 1 GB or less on an 8 GB host:

| Model | Context (tokens) |
|-------|------------------|
| `qwen2.5-0.5b`, `qwen2.5-1.5b`, `llama-3.2-1b` | 16384 |
| `gemma-2-2b`, `llama-3.2-3b` | 8192 |
| `smollm2-1.7b` | 4096 |
| `phi-3.5-mini` | 3072 |

Open WebUI can add several thousand tokens of its own to every request (tool definitions and system prompts), so a one-line question may already be 6,000 tokens or more. If you still hit the limit, either raise it for all models with `CTX_SIZE=16384 bash deploy-vllm-kind.sh` (more RAM per model; watch for `OOMKilled`), or trim what Open WebUI sends: in the chat, open the controls (sliders icon) and switch off tools and features you don't use, or in Admin Panel > Settings > Models edit the model and turn off the built-in tools capability (names vary by Open WebUI version).

How it behaves:
- **First message to a model:** it takes longer (10 to 60 seconds) while the model loads into RAM. Switching models in the dropdown has the same short delay.
- **Disk:** all 7 models need about 9.5 GB, plus about 6 GB for the cluster images, so plan for 25 GB free or more. Use `MODELS=` to pick fewer.
- **Memory:** `llama-3.2-3b` and `phi-3.5-mini` are tight on 8 GB with the chat UI running. If the pod shows `OOMKilled`, use `ENABLE_WEBUI=false` and test through the API.
- **Only `/v1` and `/health` are exposed** through the ingress. llama-swap's own `/ui` and `/logs` pages stay inside the cluster, because the logs can contain the llama-server command line (which includes the API key).
- **Switching between modes** (multi and single) replaces the model server pod; the downloaded files stay on the volume.
- To add a model, add a line to `models.conf` (key, GGUF repo, GGUF file name, vLLM model id, size, notes) and re-run the script.

## 5. Manage

```bash
bash deploy-vllm-kind.sh status      # pods, services, ingress, PVCs
bash deploy-vllm-kind.sh key         # print the API key
bash deploy-vllm-kind.sh destroy     # delete the cluster
kubectl logs -n vllm deployment/vllm -f
```

## Options (environment variables)

| Variable | Default | Notes |
|----------|---------|-------|
| `BACKEND` | `auto` | `auto`, `vllm` or `llamacpp` |
| `ENABLE_WEBUI` | `true` | `false` skips Open WebUI (saves RAM) |
| `VLLM_HOST` / `WEBUI_HOST` | nip.io on EC2 IP | Override with your own DNS |
| `PUBLIC_IP` | auto-detected | Set if the metadata service is blocked |
| `LLAMA_IMAGE` | `ghcr.io/ggml-org/llama.cpp:server` | llama.cpp backend image |
| `VLLM_IMAGE` | vLLM CPU release image | Verify the tag in the vLLM CPU docs |
| `MULTI_MODEL` | `true` | `true`: llama-swap serves all selected models; `false`: single model (`MODEL`) |
| `MODELS` | `all` | Comma list of catalog keys to serve in multi-model mode |
| `MODEL` | `qwen2.5-0.5b` | Single-model key; in multi-model mode, the model used for the final test |
| `SWAP_LOG_LEVEL` | unset | `debug` makes llama-swap print llama-server's own log lines (prompt token counts, timings) |
| `LLAMA_SWAP_IMAGE` | `ghcr.io/mostlygeek/llama-swap:cpu` | Router image (includes llama-server) |
| `MODEL_NAME` | from catalog | Override the Hugging Face id (vLLM backend only) |
| `WEBUI_IMAGE` | `ghcr.io/open-webui/open-webui:main` | |
| `HF_TOKEN` | empty | Only for gated models |
| `CLUSTER_NAME` | `vllm-kind` | |

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `ERROR: docker not found` | Install tools (section 2) |
| `error: no matching resources found` right after the ingress install | Old script version; use the current one (it waits with `rollout status`) |
| vllm pod `Pending` | CPU requests too high for 2 vCPU. Check `kubectl describe pod -n vllm -l app=vllm`; this version requests 250m |
| `no space left on device` / `failed to extract layer` | Disk too small. Grow to 30 GB or more, `docker system prune -af`, then `kubectl rollout restart deployment/vllm -n vllm` |
| `InvalidImageName` showing `${LLAMA_IMAGE}` | Manifest applied without the script. Re-run the script, or `kubectl set image deployment/vllm -n vllm llama=ghcr.io/ggml-org/llama.cpp:server` |
| `ErrImagePull` | Test `docker pull <image>` on the host; if that works, `kind load docker-image <image> --name vllm-kind` |
| llama.cpp: `error: invalid argument: --flag=value` | llama.cpp needs `--flag value` as separate args (already fixed in `vllm-kind-llamacpp.yaml`) |
| vLLM CPU image crashes (illegal instruction) | CPU lacks AVX512; use `BACKEND=llamacpp` |
| open-webui `OOMKilled` | Use `ENABLE_WEBUI=false` |
| 404 from the ingress | Host header doesn't match `VLLM_HOST` / `WEBUI_HOST` |
| Browser can't connect | Security group port 80, or the cluster was created without the port mapping (`destroy`, then `up`) |
| `ERROR: existing model-cache PVC is 5Gi` | Cluster created by an older version. Run `bash deploy-vllm-kind.sh destroy`, then run the script again |
| `request (N tokens) exceeds the available context size` | Context window too small for what Open WebUI sends. Use the current version of this zip, or `CTX_SIZE=16384 bash deploy-vllm-kind.sh`. See the context table above |
| Chat UI replies very slowly or looks stuck, but `curl` to the API is fast | Open WebUI sends thousands of extra tokens per message, plus background calls (title, tags, follow-ups) that queue on 2 vCPUs. Switch the background tasks off in Admin Panel > Settings > Interface (this version of the zip sets them off on a fresh install), use `qwen2.5-1.5b` or smaller, and check `top -b -n 1 \| head -12` (`llama-server` pinned above 150% means it is still working). To see each request's token count: `SWAP_LOG_LEVEL=debug bash deploy-vllm-kind.sh`, then `kubectl logs -n vllm deployment/vllm -c llama -f` while you send a message |
| Model shows in the UI but the first reply is slow or times out | The model is loading (or still downloading). Check `kubectl logs -n vllm deployment/vllm -c fetch-models` and `kubectl logs -n vllm deployment/vllm -c llama` |
| Init container `fetch-models` keeps restarting | Disk full or Hugging Face unreachable: `kubectl logs -n vllm deployment/vllm -c fetch-models`; free space with `df -h /`; use `MODELS=` to fetch fewer |
| Multi-model mode fails and you need a working setup now | `MULTI_MODEL=false bash deploy-vllm-kind.sh` (single model, the earlier proven path) |
| `ERROR: unknown MODEL` | Use a key from `bash deploy-vllm-kind.sh models` |
| A non-admin Open WebUI user sees no models | Open WebUI hides models from non-admins until access is granted. This zip sets `BYPASS_MODEL_ACCESS_CONTROL=true` on a fresh install. On an existing install run `kubectl set env deployment/open-webui -n vllm BYPASS_MODEL_ACCESS_CONTROL=true`, or grant access per model in Admin Panel > Settings > Models |
| 401 on `/v1/*` | Missing or wrong `Authorization: Bearer <key>` |

## Security notes

- Plain HTTP only. Restrict port 80 to your IP and disable Open WebUI sign-ups after creating the admin account.
- Rotate the API key: `kubectl delete secret vllm-api-key -n vllm`, re-run the script, then `kubectl rollout restart deployment/vllm deployment/open-webui -n vllm`.
- Cleanup when done: `bash deploy-vllm-kind.sh destroy`.
