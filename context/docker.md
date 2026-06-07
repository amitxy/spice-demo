# Docker image — one-click Vast.ai deploy

A self-contained image that runs the inference server with **both GGUF models
baked in** and the SvelteKit UI embedded. Standing up a new instance is "pick
image → run" — no submodule init, no CUDA build, no model download at boot.

This is a **parallel** deployment path; the hand-provisioned box (with
`server/public-serve.sh` + `/etc/vast_boot.d`) is unchanged.

## What's in the image

| Layer | Contents |
|-------|----------|
| models (`/app/models`) | `spice-finetuned.gguf`, `qwen3.5-9b-base.gguf` (~10.7 GB, stable/cached) |
| binary (`/app/bin`) | CUDA `llama-server` + `libggml*`/`libllama` shared libs |
| config (`/app`) | `chat_template.jinja`, `inference-config.json`, `entrypoint.sh` |
| tools | `cloudflared`, `tini`, `curl`, `python3` |

Built by `Dockerfile` (4 stages: `ui-builder` → `bin-builder` → `model-fetcher`
→ `runtime`). Final image ~12–13 GB.

## Prerequisites

- A Docker host with **BuildKit** (Docker ≥ 23, or `DOCKER_BUILDKIT=1`).
  **No GPU needed to build** — CUDA cross-compiles in the devel image.
- A Hugging Face token with access to the **private** finetuned repo
  (`Amitxy/spice-qwen3.5-9b-constitution-sft-gguf`). The base repo is public.
  Resolved from `$HF_TOKEN` or `huggingface_api_key` in `.env`.
- `docker login ghcr.io` once (a GitHub PAT with `write:packages`).

## Build & push — GitHub Actions (recommended, no local Docker)

`.github/workflows/docker-image.yml` builds and pushes to ghcr **inside
GitHub's network** (fast push, no egress cost, HF token stays an encrypted
secret). One-time setup:

1. **Add the HF token** as a repo secret: GitHub → Settings → Secrets and
   variables → Actions → New repository secret → name `HF_TOKEN`, value = your
   Hugging Face token (needs access to the private finetuned repo).
2. **Run it:** Actions tab → "Build & push server image" → *Run workflow*
   (optional inputs: `tag`, `cuda_archs`). Or push a `v*` git tag.
3. **First push creates a *private* package.** To make pulls free, set it public:
   your profile → Packages → `spice-demo` → Package settings → Change visibility →
   Public. (Keep private only if you accept ghcr private storage/egress costs.)

The build takes ~30–45 min (CUDA compile + ~10.7 GB model download). It is **not**
triggered on every commit on purpose — run it when you want a new image.

> Free GitHub runners have limited disk for a ~13 GB image; the workflow runs a
> disk-reclaim step (`jlumbroso/free-disk-space`) to make room.

## Build & push — local Docker (alternative)

```bash
docker login ghcr.io
bash docker/build-and-push.sh                 # build + push ghcr.io/amitxy/spice-demo:latest
bash docker/build-and-push.sh --no-push       # build only
IMAGE=ghcr.io/amitxy/spice-demo:dev CUDA_ARCHS="86" bash docker/build-and-push.sh --no-push
```

- `CUDA_ARCHS` (default `80;86;89` = A100 / Ampere-consumer / Ada). Add `75`
  (Turing) or `90` (Hopper) to run on more GPUs, at the cost of build time. A
  single arch (e.g. `86` for a 3060/3090) builds fastest.
- The HF token is passed as a **BuildKit secret** (`--secret`) — it is used only
  in the `model-fetcher` RUN and never written to an image layer.
- **Where to build:** the 10.7 GB model layer is pushed **once** (cached on later
  code changes). Build/push from a fast-uplink host. This Vast box can't build
  unless it has a working Docker daemon (DinD is unreliable) — prefer a normal
  Docker host or CI. Note: free GitHub Actions runners have ~14 GB disk, too
  tight for a 13 GB image build.

## Run locally (GPU host)

```bash
docker run --rm --gpus all -p 8000:8000 ghcr.io/amitxy/spice-demo:latest
curl localhost:8000/health        # {"status":"ok"} once the model loads
curl localhost:8000/v1/models     # spice-finetuned, qwen3.5-9b-base
```

The container logs print the cloudflared `trycloudflare.com` URL once it's up.

### Tunables (`-e`)

| Env | Default | Meaning |
|-----|---------|---------|
| `PORT` | `8000` | listen port |
| `ENABLE_TUNNEL` | `true` | start the cloudflared quick tunnel (`false` = Vast port mapping only) |
| `CTX_SIZE` | `32768` | context window |
| `PARALLEL` | `2` | concurrent slots |
| `MODELS_MAX` | `1` | models in VRAM at once (hot-swap) |
| `N_GPU_LAYERS` | `999` | GPU offload |

## Launch on Vast.ai

1. **Image:** `ghcr.io/amitxy/spice-demo:latest` (add a registry login in the
   Vast template if you keep the package private).
2. **Ports:** expose `8000` — Vast maps it to a public `host:port` (native,
   stable per instance). This is the primary public address.
3. Leave the default nvidia runtime (GPU passthrough). No on-start script needed
   — the image `ENTRYPOINT` runs the server.
4. **Public access is twofold:** the Vast-mapped port (stable) **and** the
   cloudflared URL printed in the instance logs (ephemeral). Set
   `ENABLE_TUNNEL=false` to use Vast mapping only.

## Verify a fresh deploy

`/health` → 200, `/v1/models` lists both models, UI defaults to
`spice-finetuned`, the personality list shows **None**, and one
`/v1/chat/completions` returns a completion. Confirm the token didn't leak:
`docker run --rm ghcr.io/amitxy/spice-demo:latest env | grep -i hf` → empty.
