#!/usr/bin/env bash
# Installs the spice-demo public-serve boot hook into Vast.ai's boot directory.
# Run this once after recreating the instance from the base image (the /etc hook
# is reset on recreate; /workspace and this repo persist). Idempotent.
set -euo pipefail

REPO="/workspace/spice-demo"
SRC="$REPO/server/vast-boot-hook.sh"
DEST="/etc/vast_boot.d/90-spice-public-tunnel.sh"

[ -f "$SRC" ] || { echo "[install-boot-hook] missing $SRC"; exit 1; }
[ -d /etc/vast_boot.d ] || { echo "[install-boot-hook] /etc/vast_boot.d not found — not a Vast.ai instance?"; exit 1; }

install -m 0755 "$SRC" "$DEST"
chmod +x "$REPO/server/public-serve.sh"

echo "[install-boot-hook] installed $DEST"
echo "[install-boot-hook] the server + public tunnel will now start on every boot."
echo "[install-boot-hook] current/last public URL (after boot) is written to:"
echo "                    $REPO/PUBLIC_URL.txt"
