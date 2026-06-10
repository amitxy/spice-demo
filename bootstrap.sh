#!/usr/bin/env bash
# One-shot bring-up for a fresh GPU instance.
#
# Takes a bare Ubuntu 22.04 + NVIDIA box (CUDA runtime present, but no compiler /
# build toolchain) all the way to a running, publicly-tunneled inference server:
#
#   deps -> CUDA compiler -> Node -> cloudflared -> submodule -> build (native arch)
#        -> models -> start llama-server -> cloudflared quick tunnel -> print URL
#
# Reuses the repo's own pieces: server/build.sh (UI + binary), server/download_models.py
# (canonical model fetch). Run as root from anywhere:
#
#   HF_TOKEN=hf_xxx bash bootstrap.sh
#
# Idempotent: every step skips when already satisfied, so re-running is safe and
# will not disturb an already-running server/tunnel.
#
# Tunables (env):
#   MODELS_DIR=/models   PORT=8000   ENABLE_TUNNEL=true   FORCE_BUILD=0
#   HF_TOKEN=...         only needed if a model is missing from MODELS_DIR
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

MODELS_DIR="${MODELS_DIR:-/models}"
PORT="${PORT:-8000}"
ENABLE_TUNNEL="${ENABLE_TUNNEL:-true}"
FORCE_BUILD="${FORCE_BUILD:-0}"
SRV_LOG="/tmp/llama-server.log"
CF_LOG="/tmp/cloudflared.log"
URL_FILE="$REPO_ROOT/PUBLIC_URL.txt"

LLAMA_BIN="$REPO_ROOT/server/llama.cpp/build/bin/llama-server"

log() { echo "[bootstrap] $*"; }

if [ "$(id -u)" -ne 0 ]; then
    log "ERROR: must run as root (installs system packages). Try: sudo bash bootstrap.sh"
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------------------
log "installing base packages (apt)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -q --no-install-recommends \
    build-essential cmake git ca-certificates curl python3 python3-pip

# ---------------------------------------------------------------------------
# 2. CUDA compiler (runtime libs are usually present on a GPU instance; nvcc is not)
# ---------------------------------------------------------------------------
find_nvcc() {
    command -v nvcc 2>/dev/null && return 0
    local c
    for c in /usr/local/cuda/bin/nvcc /usr/local/cuda-*/bin/nvcc; do
        [ -x "$c" ] && { echo "$c"; return 0; }
    done
    return 1
}

if find_nvcc >/dev/null; then
    log "nvcc already present: $(find_nvcc)"
else
    # Derive the CUDA version (e.g. 12.4 -> 12-4) from the installed runtime; default 12-4.
    ver="12-4"
    for d in /usr/local/cuda-*; do
        [ -d "$d" ] || continue
        v="${d##*/cuda-}"                       # e.g. 12.4
        ver="${v%.*}-${v#*.}"                   # 12-4
        break
    done
    log "nvcc missing -> installing CUDA compiler packages (cuda-$ver)..."
    if ! ls /etc/apt/sources.list.d/cuda*.list >/dev/null 2>&1; then
        log "adding NVIDIA CUDA apt repo (cuda-keyring)..."
        curl -fsSL -o /tmp/cuda-keyring.deb \
            https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
        dpkg -i /tmp/cuda-keyring.deb
        apt-get update -qq
    fi
    apt-get install -y -q --no-install-recommends \
        "cuda-nvcc-${ver}" "cuda-cudart-dev-${ver}" "libcublas-dev-${ver}"
fi

# ---------------------------------------------------------------------------
# 3. Node >= 18 (apt's nodejs is v12, too old for the SvelteKit UI)
# ---------------------------------------------------------------------------
node_major="$(node --version 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/')" || node_major=0
if [ "${node_major:-0}" -ge 18 ] 2>/dev/null; then
    log "node $(node --version) already present"
else
    log "installing Node 20 via NodeSource..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y -q nodejs
fi

# ---------------------------------------------------------------------------
# 4. cloudflared
# ---------------------------------------------------------------------------
if command -v cloudflared >/dev/null 2>&1; then
    log "cloudflared already present: $(command -v cloudflared)"
else
    log "installing cloudflared..."
    curl -fsSL -o /usr/local/bin/cloudflared \
        https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    chmod +x /usr/local/bin/cloudflared
fi
CF_BIN="$(command -v cloudflared)"

# ---------------------------------------------------------------------------
# 5. CUDA environment (build needs nvcc on PATH; runtime needs the libs on LD path)
# ---------------------------------------------------------------------------
CUDA_HOME=""
for d in /usr/local/cuda /usr/local/cuda-*; do
    [ -d "$d" ] && { CUDA_HOME="$d"; break; }
done
if [ -n "$CUDA_HOME" ]; then
    export PATH="$CUDA_HOME/bin:$PATH"
    export LD_LIBRARY_PATH="$CUDA_HOME/lib64:${LD_LIBRARY_PATH:-}"
    log "CUDA_HOME=$CUDA_HOME"
else
    log "WARNING: no /usr/local/cuda* found; relying on PATH for nvcc"
fi

# ---------------------------------------------------------------------------
# 6. llama.cpp submodule
# ---------------------------------------------------------------------------
log "ensuring llama.cpp submodule is checked out..."
git -C "$REPO_ROOT" submodule update --init server/llama.cpp

# ---------------------------------------------------------------------------
# 7. Build UI + CUDA binary (native arch)
# ---------------------------------------------------------------------------
if [ -x "$LLAMA_BIN" ] && [ "$FORCE_BUILD" != "1" ]; then
    log "llama-server already built ($LLAMA_BIN) -> skipping build (FORCE_BUILD=1 to rebuild)"
else
    # || true: under `set -e -o pipefail` a failing nvidia-smi would otherwise abort here.
    arch="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d ' .' || true)"
    [ -n "$arch" ] || arch="86"
    log "building (CUDA_ARCHS=$arch)... this is the slow step on a fresh instance"
    CUDA_ARCHS="$arch" bash "$REPO_ROOT/server/build.sh"
fi

# ---------------------------------------------------------------------------
# 8. Models
# ---------------------------------------------------------------------------
mkdir -p "$MODELS_DIR"
if [ -f "$MODELS_DIR/spice-finetuned.gguf" ] && [ -f "$MODELS_DIR/qwen3.5-9b-base.gguf" ]; then
    log "models already present in $MODELS_DIR -> skipping download"
else
    log "a model is missing -> downloading into $MODELS_DIR (needs HF_TOKEN for the private repo)"
    python3 -m pip install --quiet --no-cache-dir "huggingface_hub>=0.23,<1.0"
    python3 "$REPO_ROOT/server/download_models.py" --models-dir "$MODELS_DIR"
fi

# ---------------------------------------------------------------------------
# 9. Start llama-server
# ---------------------------------------------------------------------------
if pgrep -f 'llama-server.*--models-dir' >/dev/null 2>&1; then
    log "llama-server already running."
else
    log "starting llama-server on :$PORT (logs: $SRV_LOG)..."
    KWARGS="$(python3 -c "import json; print(json.dumps(json.load(open('$REPO_ROOT/server/inference-config.json'))))")"
    nohup "$LLAMA_BIN" \
        --models-dir "$MODELS_DIR" --models-max 1 \
        --jinja --chat-template-file "$REPO_ROOT/server/chat_template.jinja" \
        --chat-template-kwargs "$KWARGS" \
        --host 0.0.0.0 --port "$PORT" \
        --n-gpu-layers 999 --ctx-size 32768 --parallel 2 --cont-batching \
        --reasoning-format deepseek --reasoning on \
        > "$SRV_LOG" 2>&1 &
    log "llama-server PID $!."
fi

# Wait for health (cold model load can be slow).
log "waiting for server health on :$PORT ..."
for _ in $(seq 1 90); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/health" 2>/dev/null)" = "200" ] && break
    sleep 2
done
if [ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/health" 2>/dev/null)" != "200" ]; then
    log "WARNING: server not healthy yet; see $SRV_LOG"
fi

# ---------------------------------------------------------------------------
# 10. Public cloudflared quick tunnel
# ---------------------------------------------------------------------------
PUBLIC_URL=""
if [ "$ENABLE_TUNNEL" = "true" ]; then
    if pgrep -f 'cloudflared.*tunnel.*--url' >/dev/null 2>&1; then
        log "cloudflared tunnel already running -> re-scraping URL."
    else
        log "starting cloudflared quick tunnel..."
        : > "$CF_LOG"
        nohup "$CF_BIN" tunnel --url "http://localhost:$PORT" --no-autoupdate > "$CF_LOG" 2>&1 &
        log "cloudflared PID $!."
    fi
    for _ in $(seq 1 30); do
        # -a: cloudflared's log can contain NUL bytes, which makes plain grep treat
        # the file as binary and refuse to print matches.
        # || true: under `set -e -o pipefail`, grep finding nothing (rc 1) on an early
        # poll would otherwise abort the whole script before the URL is even written.
        PUBLIC_URL="$(grep -a -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | head -1 || true)"
        [ -n "$PUBLIC_URL" ] && break
        sleep 1
    done
    if [ -n "$PUBLIC_URL" ]; then
        printf '%s\n# generated %s\n' "$PUBLIC_URL" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$URL_FILE"
    elif grep -aq '429 Too Many Requests' "$CF_LOG" 2>/dev/null; then
        log "WARNING: Cloudflare is rate-limiting quick tunnels (HTTP 429). Wait a few"
        log "         minutes and re-run (the server is up regardless), or set ENABLE_TUNNEL=false."
    else
        log "WARNING: could not obtain tunnel URL; see $CF_LOG"
    fi
fi

# ---------------------------------------------------------------------------
# 11. Summary
# ---------------------------------------------------------------------------
echo
log "=== ready ==="
log "local : http://localhost:$PORT"
[ -n "$PUBLIC_URL" ] && log "public: $PUBLIC_URL  (also in $URL_FILE)"
log "logs  : server=$SRV_LOG  tunnel=$CF_LOG"
