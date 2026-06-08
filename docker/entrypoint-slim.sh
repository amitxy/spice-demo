#!/usr/bin/env bash
# Slim-variant entrypoint: the image ships WITHOUT models. On boot we ensure both
# GGUF models exist in $MODELS_DIR (downloading any that are missing), then start
# the server. Mount a persistent volume at $MODELS_DIR so the ~10.7 GB download
# happens only once. Requires HF_TOKEN at runtime for the private finetuned repo.
set -u

PORT="${PORT:-8000}"
MODELS_DIR="${MODELS_DIR:-/models}"
CFG=/app/inference-config.json
CF_LOG=/tmp/cloudflared.log
URL_FILE=/app/PUBLIC_URL.txt

mkdir -p "$MODELS_DIR"

# Key-based SSH (Vast injects your key via PUBLIC_KEY). No-op without a key.
[ -x /app/ssh-setup.sh ] && /app/ssh-setup.sh || true

# Ensure both models are present (idempotent: skips anything already downloaded).
# Single source of truth -- the same script used to populate server/models on a
# host. It auto-detects the finetuned gguf, enforces the canonical filenames, and
# reads the token from $HF_TOKEN. Exits non-zero on failure -> abort the boot.
echo "[entrypoint] ensuring models in ${MODELS_DIR} ..."
if ! python3 /app/download_models.py --models-dir "$MODELS_DIR"; then
    echo "[entrypoint] ERROR: model download failed; aborting." >&2
    exit 1
fi

# Optional public cloudflared quick tunnel (Vast also maps the EXPOSEd port).
if [ "${ENABLE_TUNNEL:-true}" = "true" ]; then
    echo "[entrypoint] starting cloudflared quick tunnel -> http://localhost:${PORT}"
    : > "$CF_LOG"
    cloudflared tunnel --url "http://localhost:${PORT}" --no-autoupdate > "$CF_LOG" 2>&1 &
    (
        for _ in $(seq 1 30); do
            URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | head -1)
            if [ -n "$URL" ]; then
                echo "$URL" > "$URL_FILE"
                echo "[entrypoint] PUBLIC TUNNEL URL: $URL"
                break
            fi
            sleep 1
        done
    ) &
fi

KWARGS="$(python3 -c "import json; print(json.dumps(json.load(open('${CFG}'))))")"

echo "[entrypoint] launching llama-server on :${PORT} (models dir: ${MODELS_DIR})"
exec /app/bin/llama-server \
    --models-dir "${MODELS_DIR}" \
    --models-max "${MODELS_MAX:-1}" \
    --jinja --chat-template-file /app/chat_template.jinja \
    --chat-template-kwargs "${KWARGS}" \
    --host 0.0.0.0 --port "${PORT}" \
    --n-gpu-layers "${N_GPU_LAYERS:-999}" \
    --ctx-size "${CTX_SIZE:-32768}" --parallel "${PARALLEL:-2}" --cont-batching \
    --reasoning-format deepseek --reasoning on
