#!/usr/bin/env bash
# Container entrypoint: optionally start a public cloudflared quick tunnel, then
# exec llama-server in the foreground (PID 1 under tini) so the container's
# lifecycle tracks the server. Configurable via env (see Dockerfile defaults).
set -u

PORT="${PORT:-8000}"
CFG=/app/inference-config.json
CF_LOG=/tmp/cloudflared.log
URL_FILE=/app/PUBLIC_URL.txt

# Key-based SSH (Vast injects your key via PUBLIC_KEY). No-op without a key.
[ -x /app/ssh-setup.sh ] && /app/ssh-setup.sh || true

# Public access #1 — Vast maps EXPOSE 8000 to a host:port automatically.
# Public access #2 — cloudflared quick tunnel (toggle with ENABLE_TUNNEL=false).
if [ "${ENABLE_TUNNEL:-true}" = "true" ]; then
    echo "[entrypoint] starting cloudflared quick tunnel -> http://localhost:${PORT}"
    : > "$CF_LOG"
    cloudflared tunnel --url "http://localhost:${PORT}" --no-autoupdate \
        > "$CF_LOG" 2>&1 &
    # Surface the generated URL in the container logs once it appears.
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

# Server-wide thinking_prefix from inference-config.json (same one-liner the
# host run command and restart-server.sh use).
KWARGS="$(python3 -c "import json; print(json.dumps(json.load(open('${CFG}'))))")"

echo "[entrypoint] launching llama-server on :${PORT}"
exec /app/bin/llama-server \
    --models-dir /app/models \
    --models-max "${MODELS_MAX:-1}" \
    --jinja --chat-template-file /app/chat_template.jinja \
    --chat-template-kwargs "${KWARGS}" \
    --host 0.0.0.0 --port "${PORT}" \
    --n-gpu-layers "${N_GPU_LAYERS:-999}" \
    --ctx-size "${CTX_SIZE:-32768}" --parallel "${PARALLEL:-2}" --cont-batching \
    --reasoning-format deepseek --reasoning on
