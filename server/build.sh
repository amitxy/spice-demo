#!/usr/bin/env bash
# Build the llama-server binary with the custom UI embedded.
#
# Usage:
#   ./server/build.sh            # full build (UI + binary)
#   ./server/build.sh --ui-only  # rebuild UI and copy dist only
#   ./server/build.sh --bin-only # recompile binary (assumes dist already copied)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_DIR="$SCRIPT_DIR/ui"
LLAMA_DIR="$SCRIPT_DIR/llama.cpp"
LLAMA_UI_DIST="$LLAMA_DIR/tools/ui/dist"

MODE="${1:-}"

build_ui() {
    echo "==> Building UI..."
    cd "$UI_DIR"
    npm install --silent
    npm run build
    echo "==> Copying dist to llama.cpp/tools/ui/dist/ (gitignored inside submodule)..."
    rm -rf "$LLAMA_UI_DIST"
    cp -r "$UI_DIR/dist" "$LLAMA_UI_DIST"
}

build_binary() {
    echo "==> Configuring llama.cpp..."
    cd "$LLAMA_DIR"
    cmake -B build \
        -DGGML_CUDA=ON \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLAMA_BUILD_UI=OFF
    echo "==> Compiling llama-server..."
    cmake --build build --target llama-server -j"$(nproc)"
    echo "==> Binary: $LLAMA_DIR/build/bin/llama-server"
}

case "$MODE" in
    --ui-only)  build_ui ;;
    --bin-only) build_binary ;;
    *)          build_ui && build_binary ;;
esac
