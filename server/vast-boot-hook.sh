#!/bin/bash
# Vast.ai boot hook (sourced by /opt/instance-tools/bin/boot_default.sh at boot).
# Brings up the spice-demo inference server + public cloudflared quick tunnel.
#
# This is the canonical, repo-tracked copy. install-boot-hook.sh copies it to
# /etc/vast_boot.d/90-spice-public-tunnel.sh (which is NOT persistent across an
# instance *recreate* — only across normal stop/start).
#
# IMPORTANT: this file is *sourced*, not executed, so it must not call `exit` and
# must not block. It backgrounds the real worker and returns immediately so boot
# continues. The worker lives in the persistent /workspace volume.
if [ -x /workspace/spice-demo/server/public-serve.sh ]; then
    nohup /workspace/spice-demo/server/public-serve.sh \
        > /tmp/spice-public-tunnel.boot.log 2>&1 &
fi
