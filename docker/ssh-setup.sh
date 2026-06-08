#!/usr/bin/env bash
# Key-based SSH for the container, matching Vast.ai's convention: Vast injects your
# account's public key(s) into the PUBLIC_KEY env var. We add it to authorized_keys
# and start sshd. Called by the entrypoints (sshd daemonizes and returns).
#
# Security: NO-OP if no public key is supplied, so the SSH port is never open
# without a key. Password auth is disabled; root login is key-only.
set -u

SSH_PORT="${SSH_PORT:-22}"
AUTHK=/root/.ssh/authorized_keys

mkdir -p /root/.ssh && chmod 700 /root/.ssh
touch "$AUTHK"
# Vast sets PUBLIC_KEY; SSH_PUBKEY is a generic alias for non-Vast hosts.
[ -n "${PUBLIC_KEY:-}" ] && printf '%s\n' "${PUBLIC_KEY}" >> "$AUTHK"
[ -n "${SSH_PUBKEY:-}" ] && printf '%s\n' "${SSH_PUBKEY}" >> "$AUTHK"
# Drop blank lines and dedupe.
sed -i '/^[[:space:]]*$/d' "$AUTHK"
sort -u "$AUTHK" -o "$AUTHK"
chmod 600 "$AUTHK"

if [ ! -s "$AUTHK" ]; then
    echo "[ssh] no PUBLIC_KEY/SSH_PUBKEY provided -> sshd NOT started (set one to enable SSH)."
    exit 0
fi

ssh-keygen -A >/dev/null 2>&1   # generate host keys if missing
mkdir -p /run/sshd
echo "[ssh] starting sshd on :${SSH_PORT} (key-only, root via key)"
/usr/sbin/sshd -p "${SSH_PORT}" \
    -o PasswordAuthentication=no \
    -o PermitRootLogin=prohibit-password \
    -o PubkeyAuthentication=yes
