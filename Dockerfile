# syntax=docker/dockerfile:1.7
#
# Self-contained image for the spice-demo inference server: a CUDA build of
# llama.cpp with the embedded SvelteKit UI and both GGUF models baked in.
# Multi-stage: ui-builder -> bin-builder -> model-fetcher -> runtime.
#
# Build (BuildKit required, HF token needed for the private finetuned repo):
#   DOCKER_BUILDKIT=1 docker build --secret id=hf_token,src=./.hf_token \
#     -t ghcr.io/amitxy/spice-demo:latest .
# See docker/build-and-push.sh and context/docker.md.

# ---------------------------------------------------------------------------
# Stage 1: build the SvelteKit UI (constitutions + inference-config embedded)
# ---------------------------------------------------------------------------
FROM node:22-bookworm-slim AS ui-builder
WORKDIR /build
# Preserve the relative layout the prebuild scripts expect: generate-*.mjs
# resolve ../../constitutions.json, ../../inference-config.json and the
# constitution markdown under data/constitutions/ via __dirname.
COPY server/ui/ server/ui/
COPY server/constitutions.json server/inference-config.json server/
COPY data/constitutions/ data/constitutions/
WORKDIR /build/server/ui
RUN npm ci
RUN npm run build   # -> /build/server/ui/dist

# ---------------------------------------------------------------------------
# Stage 2: compile llama-server (CUDA) with the UI dist embedded
# ---------------------------------------------------------------------------
FROM nvidia/cuda:12.4.1-devel-ubuntu22.04 AS bin-builder
ARG LLAMA_CPP_COMMIT=a731805cedc83c0514cbd808a2e38ec46c759cc2
# Common datacenter/consumer arches: A100(80), 3060/3090(86), 4090(89).
# Add 75 (Turing) / 90 (Hopper) here at the cost of build time.
ARG CUDA_ARCHS=80;86;89
RUN apt-get update && apt-get install -y --no-install-recommends \
        git cmake build-essential ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN git clone https://github.com/ggerganov/llama.cpp.git /llama.cpp \
    && git -C /llama.cpp checkout ${LLAMA_CPP_COMMIT}
# Priority-1 path in llama.cpp's ui-assets.cmake: prebuilt dist is used as-is
# and its own npm build is skipped (mirrors server/build.sh).
COPY --from=ui-builder /build/server/ui/dist /llama.cpp/tools/ui/dist
RUN cmake -S /llama.cpp -B /llama.cpp/build \
        -DGGML_CUDA=ON \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLAMA_BUILD_UI=OFF \
        -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCHS}" \
    && cmake --build /llama.cpp/build --target llama-server -j"$(nproc)"

# ---------------------------------------------------------------------------
# Stage 3: download both GGUF models (token only present during this RUN)
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS model-fetcher
RUN pip install --no-cache-dir "huggingface_hub>=0.23,<1.0"
# hf_token is a BuildKit secret -> never written to an image layer.
RUN --mount=type=secret,id=hf_token \
    HF_TOKEN="$(cat /run/secrets/hf_token 2>/dev/null || true)" \
    python - <<'PY'
import os, sys, shutil
from huggingface_hub import hf_hub_download, list_repo_files

token = (os.environ.get("HF_TOKEN") or "").strip() or None
print(f"[model-fetcher] HF token present: {bool(token)} (len={len(token or '')})", flush=True)
print(f"[model-fetcher] free disk on /: {shutil.disk_usage('/').free/1e9:.1f} GB", flush=True)
os.makedirs("/models", exist_ok=True)

def fetch(repo, fname, dest, token=None):
    print(f"[model-fetcher] downloading {repo}/{fname} ...", flush=True)
    try:
        p = hf_hub_download(repo, fname, local_dir="/dl", token=token)
    except Exception as e:
        sys.exit(f"[model-fetcher] FAILED to download {repo}/{fname}: {type(e).__name__}: {e}")
    os.replace(p, dest)
    print(f"[model-fetcher]   -> {dest} ({os.path.getsize(dest)/1e9:.2f} GB)", flush=True)

# Base model (public) -> UI model id "qwen3.5-9b-base".
fetch("unsloth/Qwen3.5-9B-GGUF", "Qwen3.5-9B-Q4_K_M.gguf",
      "/models/qwen3.5-9b-base.gguf", token=token)

# Finetuned model (PRIVATE repo -> token required). Fail fast with a clear
# message rather than a confusing 401 if the HF_TOKEN secret is missing.
FT_REPO = "Amitxy/spice-qwen3.5-9b-constitution-sft-gguf"
if not token:
    sys.exit(f"[model-fetcher] ERROR: HF_TOKEN secret is empty, but {FT_REPO} is "
             "private. Add an HF_TOKEN repository secret (Actions) whose token can "
             "read that repo.")
# Auto-detect the .gguf filename in the repo (the exact name isn't hardcoded, so a
# renamed/re-uploaded checkpoint keeps working). Saved as spice-finetuned.gguf -
# the UI's default model id.
ft_files = [f for f in list_repo_files(FT_REPO, token=token) if f.endswith(".gguf")]
if not ft_files:
    sys.exit(f"[model-fetcher] ERROR: no .gguf found in {FT_REPO}. "
             f"files: {list_repo_files(FT_REPO, token=token)}")
print(f"[model-fetcher] {FT_REPO} gguf candidates: {ft_files}", flush=True)
fetch(FT_REPO, ft_files[0], "/models/spice-finetuned.gguf", token=token)

print("[model-fetcher] models ready:", os.listdir("/models"), flush=True)
PY

# ---------------------------------------------------------------------------
# Stage 4: lean runtime image
# ---------------------------------------------------------------------------
FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04 AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl python3 tini \
    && curl -fsSL -o /usr/local/bin/cloudflared \
        https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    && chmod +x /usr/local/bin/cloudflared \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
# Models first: large, stable layer -> stays cached across code/config changes.
COPY --from=model-fetcher /models /app/models
# Binary + all its shared libs (libggml*, libllama, ...).
COPY --from=bin-builder /llama.cpp/build/bin/ /app/bin/
ENV LD_LIBRARY_PATH=/app/bin
# Runtime config + entrypoint.
COPY server/chat_template.jinja server/inference-config.json /app/
COPY docker/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Tunables (override at `docker run`/Vast launch with -e).
ENV PORT=8000 \
    CTX_SIZE=32768 \
    PARALLEL=2 \
    MODELS_MAX=1 \
    N_GPU_LAYERS=999 \
    ENABLE_TUNNEL=true

EXPOSE 8000
ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
