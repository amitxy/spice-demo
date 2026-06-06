#!/usr/bin/env bash
# Finds the running llama-server router (the binary process with --models-dir),
# reads its args directly, kills it, restarts it in the background,
# then polls /health until the server is ready.
set -euo pipefail

PORT=8000
HEALTH_URL="http://localhost:${PORT}/health"
TIMEOUT=120  # seconds to wait for server to come back up

# Find the actual llama-server binary that owns --models-dir
# (use /proc/<pid>/exe to skip bash wrappers)
ROUTER_PID=""
for pid in $(pgrep -x llama-server 2>/dev/null || true); do
    if tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | grep -q -- '--models-dir'; then
        ROUTER_PID="$pid"
        break
    fi
done

if [ -z "$ROUTER_PID" ]; then
    echo "[restart-server] llama-server router is not running — nothing to restart."
    exit 0
fi

echo "[restart-server] Found llama-server router (PID $ROUTER_PID) on port $PORT."

# Reconstruct the command as an array from null-separated /proc cmdline
mapfile -d '' ARGS < "/proc/${ROUTER_PID}/cmdline"
BINARY="${ARGS[0]}"

# Re-read --chat-template-kwargs from inference-config.json so the restarted
# server picks up any edits without needing to know the original launch CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CONFIG_FILE="$REPO_ROOT/server/inference-config.json"
if [ -f "$CONFIG_FILE" ]; then
    NEW_KWARGS=$(python3 -c "import json; print(json.dumps(json.load(open('$CONFIG_FILE'))))")
    UPDATED_ARGS=()
    SKIP_NEXT=false
    for arg in "${ARGS[@]}"; do
        if $SKIP_NEXT; then
            UPDATED_ARGS+=("$NEW_KWARGS")
            SKIP_NEXT=false
            continue
        fi
        if [ "$arg" = "--chat-template-kwargs" ]; then
            SKIP_NEXT=true
        fi
        UPDATED_ARGS+=("$arg")
    done
    ARGS=("${UPDATED_ARGS[@]}")
    echo "[restart-server] Refreshed --chat-template-kwargs from $CONFIG_FILE"
fi

echo "[restart-server] Binary: $BINARY"
echo "[restart-server] Args: ${ARGS[*]:1}"

# Kill the router; the model worker it spawned dies with it
kill "$ROUTER_PID"
echo "[restart-server] Sent SIGTERM to PID $ROUTER_PID. Waiting for it to exit..."
for i in $(seq 1 10); do
    kill -0 "$ROUTER_PID" 2>/dev/null || break
    sleep 1
done
if kill -0 "$ROUTER_PID" 2>/dev/null; then
    echo "[restart-server] Process didn't exit; sending SIGKILL..."
    kill -9 "$ROUTER_PID" 2>/dev/null || true
fi
echo "[restart-server] Process stopped."

# Restart using the exact same binary + args
LOG_FILE="/tmp/llama-server.log"
echo "[restart-server] Restarting server..."
nohup "${ARGS[@]}" > "$LOG_FILE" 2>&1 &
NEW_PID=$!
echo "[restart-server] Started with PID $NEW_PID. Logs: $LOG_FILE"

# Poll /health until ready
echo "[restart-server] Waiting for server to become healthy (up to ${TIMEOUT}s)..."
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$HEALTH_URL" 2>/dev/null || true)
    if [ "$STATUS" = "200" ]; then
        echo "[restart-server] Server is healthy at $HEALTH_URL"
        exit 0
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

echo "[restart-server] ERROR: Server did not become healthy within ${TIMEOUT}s."
echo "[restart-server] Check logs: $LOG_FILE"
exit 1
