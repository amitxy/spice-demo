#!/usr/bin/env bash
# Build the spice-demo server image (BuildKit) and push it to a registry.
# The Hugging Face token (needed for the private finetuned repo) is passed as a
# BuildKit secret so it never lands in an image layer.
#
# Usage:
#   docker login ghcr.io           # once
#   bash docker/build-and-push.sh                 # build + push :latest
#   IMAGE=ghcr.io/amitxy/spice-demo:dev bash docker/build-and-push.sh --no-push
#
# HF token resolution order: $HF_TOKEN env, else huggingface_api_key from .env.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

IMAGE="${IMAGE:-ghcr.io/amitxy/spice-demo:latest}"
CUDA_ARCHS="${CUDA_ARCHS:-80;86;89}"
PUSH=true
[ "${1:-}" = "--no-push" ] && PUSH=false

# Resolve HF token.
TOKEN="${HF_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f .env ]; then
    TOKEN="$(python3 - <<'PY'
import re
try:
    for line in open('.env'):
        m = re.match(r'\s*huggingface_api_key\s*=\s*(.*)', line)
        if m:
            print(m.group(1).strip().strip('"').strip("'").rstrip('\r'))
            break
except FileNotFoundError:
    pass
PY
)"
fi
if [ -z "$TOKEN" ]; then
    echo "ERROR: no HF token. Set HF_TOKEN or huggingface_api_key in .env" >&2
    exit 1
fi

# Write token to a transient, gitignored secret file.
SECRET_FILE="$(mktemp "${TMPDIR:-/tmp}/hf_token.XXXXXX")"
trap 'rm -f "$SECRET_FILE"' EXIT
printf '%s' "$TOKEN" > "$SECRET_FILE"

echo "==> Building $IMAGE (CUDA_ARCHS=$CUDA_ARCHS)"
DOCKER_BUILDKIT=1 docker build \
    --secret id=hf_token,src="$SECRET_FILE" \
    --build-arg CUDA_ARCHS="$CUDA_ARCHS" \
    -t "$IMAGE" .

if [ "$PUSH" = true ]; then
    echo "==> Pushing $IMAGE"
    docker push "$IMAGE"
else
    echo "==> Skipping push (--no-push)"
fi
echo "==> Done: $IMAGE"
