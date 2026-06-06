#!/usr/bin/env bash
# Brings up the spice-demo inference server and a public cloudflared quick tunnel,
# then records the freshly-generated public URL. Idempotent: if the server and/or
# tunnel are already running it leaves them alone and just re-captures the URL.
#
# Invoked at boot by /etc/vast_boot.d/90-spice-public-tunnel.sh, and runnable by hand.
# The quick-tunnel URL is ephemeral — it changes every time cloudflared restarts
# (i.e. on every reboot), which is why this script writes the current value to
# $URL_FILE instead of hardcoding it anywhere.
set -u

REPO="/workspace/spice-demo"
PORT=8000
URL_FILE="$REPO/PUBLIC_URL.txt"
SRV_LOG="/tmp/llama-server.log"
CF_LOG="/tmp/cloudflared.log"
CF_BIN="/opt/instance-tools/bin/cloudflared"

cd "$REPO" || { echo "[public-serve] repo not found at $REPO"; exit 1; }

# 1. Start llama-server if the router isn't already running.
if pgrep -f 'llama-server.*--models-dir' >/dev/null 2>&1; then
    echo "[public-serve] llama-server already running."
else
    echo "[public-serve] starting llama-server..."
    KWARGS="$(python3 -c "import json; print(json.dumps(json.load(open('server/inference-config.json'))))")"
    nohup server/llama.cpp/build/bin/llama-server \
        --models-dir server/models --models-max 1 \
        --jinja --chat-template-file server/chat_template.jinja \
        --chat-template-kwargs "$KWARGS" \
        --host 0.0.0.0 --port "$PORT" \
        --n-gpu-layers 999 --ctx-size 32768 --parallel 2 --cont-batching \
        --reasoning-format deepseek --reasoning on \
        > "$SRV_LOG" 2>&1 &
    echo "[public-serve] llama-server PID $!. Logs: $SRV_LOG"
fi

# 2. Wait for the server to become healthy (model load can be slow on a cold boot).
echo "[public-serve] waiting for server health on :$PORT ..."
for _ in $(seq 1 90); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/health" 2>/dev/null)" = "200" ] && break
    sleep 2
done
if [ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/health" 2>/dev/null)" != "200" ]; then
    echo "[public-serve] WARNING: server did not become healthy; starting tunnel anyway."
fi

# 3. Start the cloudflared quick tunnel if it isn't already running.
if pgrep -f 'cloudflared.*tunnel.*--url' >/dev/null 2>&1; then
    echo "[public-serve] cloudflared tunnel already running."
else
    echo "[public-serve] starting cloudflared quick tunnel..."
    : > "$CF_LOG"
    nohup "$CF_BIN" tunnel --url "http://localhost:$PORT" --no-autoupdate > "$CF_LOG" 2>&1 &
    echo "[public-serve] cloudflared PID $!. Logs: $CF_LOG"
fi

# 4. Capture the freshly-generated public URL.
URL=""
for _ in $(seq 1 30); do
    URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | head -1)
    [ -n "$URL" ] && break
    sleep 1
done

if [ -n "$URL" ]; then
    {
        echo "$URL"
        echo "# spice-demo public URL — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$URL_FILE"
    echo "[public-serve] PUBLIC URL: $URL"
    echo "[public-serve] written to $URL_FILE"
else
    echo "[public-serve] ERROR: could not obtain tunnel URL. See $CF_LOG"
    exit 1
fi
