# syntax=docker/dockerfile:1.7
#
# Self-contained image for the spice-demo inference server: a CUDA build of
# llama.cpp with the embedded SvelteKit UI and both GGUF models baked in.
# Multi-stage: ui-builder -> bin-builder -> runtime (models baked in runtime).
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
# npm ci is reproducible but hard-fails if the lockfile drifts; fall back to
# npm install so a minor drift doesn't break the build (matches server/build.sh).
RUN npm ci || npm install
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
# This build host has no NVIDIA driver, so libcuda.so.1 is absent. Expose the
# CUDA toolkit's driver *stub* (libcuda.so) under the soname libcuda.so.1 so the
# final link resolves the cuMem*/cuDevice* symbols. -rpath-link is link-time
# only (not baked into the binary), so at runtime the GPU host's real driver is
# used. This is why a GPU-less builder can compile a CUDA binary.
ENV LIBRARY_PATH=/usr/local/cuda/lib64/stubs
RUN ln -sf /usr/local/cuda/lib64/stubs/libcuda.so /usr/local/cuda/lib64/stubs/libcuda.so.1
# Priority-1 path in llama.cpp's ui-assets.cmake: prebuilt dist is used as-is
# and its own npm build is skipped (mirrors server/build.sh).
COPY --from=ui-builder /build/server/ui/dist /llama.cpp/tools/ui/dist
RUN cmake -S /llama.cpp -B /llama.cpp/build \
        -DGGML_CUDA=ON \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLAMA_BUILD_UI=OFF \
        -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCHS}" \
        -DCMAKE_EXE_LINKER_FLAGS="-Wl,-rpath-link,/usr/local/cuda/lib64/stubs" \
        -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-rpath-link,/usr/local/cuda/lib64/stubs" \
    && cmake --build /llama.cpp/build --target llama-server -j"$(nproc)"

# ---------------------------------------------------------------------------
# Stage 3: lean runtime image. Models are downloaded *here* (not in a separate
# stage) so they're materialized once, not duplicated across a fetcher layer and
# a copied layer -- which keeps the build inside the runner's disk budget.
# ---------------------------------------------------------------------------
FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04 AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl python3 python3-pip tini \
    && curl -fsSL -o /usr/local/bin/cloudflared \
        https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    && chmod +x /usr/local/bin/cloudflared \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Download both GGUF models into a single early layer (~10.7 GB, baked). Kept
# early + before the binary/config COPYs so it stays cache-stable across code
# changes. hf_token is a BuildKit secret -> never written to a layer. /tmp/dl
# scratch is removed in the same RUN so it doesn't bloat the layer.
RUN python3 -m pip install --no-cache-dir "huggingface_hub>=0.23,<1.0"
RUN --mount=type=secret,id=hf_token \
    HF_TOKEN="$(cat /run/secrets/hf_token 2>/dev/null || true)" \
    python3 - <<'PY'
import os, sys, shutil
from huggingface_hub import hf_hub_download, list_repo_files

token = (os.environ.get("HF_TOKEN") or "").strip() or None
print(f"[models] HF token present: {bool(token)} (len={len(token or '')})", flush=True)
print(f"[models] free disk: {shutil.disk_usage('/').free/1e9:.1f} GB", flush=True)
os.makedirs("/app/models", exist_ok=True)

def fetch(repo, fname, dest, token=None):
    print(f"[models] downloading {repo}/{fname} ...", flush=True)
    try:
        p = hf_hub_download(repo, fname, local_dir="/tmp/dl", token=token)
    except Exception as e:
        sys.exit(f"[models] FAILED {repo}/{fname}: {type(e).__name__}: {e}")
    os.replace(p, dest)
    print(f"[models]   -> {dest} ({os.path.getsize(dest)/1e9:.2f} GB)", flush=True)

# Base model (public) -> UI model id "qwen3.5-9b-base".
fetch("unsloth/Qwen3.5-9B-GGUF", "Qwen3.5-9B-Q4_K_M.gguf",
      "/app/models/qwen3.5-9b-base.gguf", token=token)

# Finetuned model (PRIVATE -> token required). Auto-detect the .gguf filename so a
# renamed checkpoint keeps working. Saved as spice-finetuned.gguf (UI default id).
FT_REPO = "Amitxy/spice-qwen3.5-9b-constitution-sft-gguf"
if not token:
    sys.exit(f"[models] ERROR: HF_TOKEN secret is empty, but {FT_REPO} is private. "
             "Add an HF_TOKEN repository secret whose token can read that repo.")
ggufs = [f for f in list_repo_files(FT_REPO, token=token) if f.endswith(".gguf")]
if not ggufs:
    sys.exit(f"[models] ERROR: no .gguf in {FT_REPO}: {list_repo_files(FT_REPO, token=token)}")
print(f"[models] {FT_REPO} gguf candidates: {ggufs}", flush=True)
fetch(FT_REPO, ggufs[0], "/app/models/spice-finetuned.gguf", token=token)

shutil.rmtree("/tmp/dl", ignore_errors=True)
print("[models] ready:", os.listdir("/app/models"), flush=True)
PY

# Binary + all its shared libs (libggml*, libllama, ...).
COPY --from=bin-builder /llama.cpp/build/bin/ /app/bin/
# APPEND, do not overwrite: the nvidia/cuda base sets LD_LIBRARY_PATH to the
# driver path (/usr/local/nvidia/lib64) where the container runtime exposes the
# real libcuda.so.1 at runtime. Overwriting it would break CUDA at startup.
ENV LD_LIBRARY_PATH=/app/bin:${LD_LIBRARY_PATH}
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
