#!/usr/bin/env python3
"""Download both GGUF models into the canonical layout the server expects.

Filenames are load-bearing: the llama.cpp router derives each UI model id from the
GGUF filename (without .gguf), and the UI's default model is 'spice-finetuned'
(server/ui/src/lib/constants/model-id.ts). So the files MUST land as:

    <models-dir>/qwen3.5-9b-base.gguf     id: qwen3.5-9b-base   (public)
    <models-dir>/spice-finetuned.gguf     id: spice-finetuned   (private, default)

Default <models-dir> is <repo>/server/models -- exactly what `--models-dir` points
at in the run command, public-serve.sh, and the docs.

The finetuned repo's gguf filename is AUTO-DETECTED (it is not 'finetuned-model.gguf',
which 404s). HF token resolution order: --token > $HF_TOKEN > huggingface_api_key in
<repo>/.env. Idempotent: a model that already exists is skipped unless --force.

Usage:
    python server/download_models.py                 # -> server/models/
    python server/download_models.py --force         # re-download
    python server/download_models.py --models-dir /models   # e.g. for a container volume
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
from pathlib import Path

# Sources (HF) -> canonical destination filename (which becomes the UI model id).
BASE_REPO = "unsloth/Qwen3.5-9B-GGUF"
BASE_FILE = "Qwen3.5-9B-Q4_K_M.gguf"
BASE_DEST = "qwen3.5-9b-base.gguf"
FT_REPO = "Amitxy/spice-qwen3.5-9b-constitution-sft-gguf"  # private
FT_DEST = "spice-finetuned.gguf"  # MUST match DEFAULT_MODEL_ID in model-id.ts

REPO_ROOT = Path(__file__).resolve().parent.parent


def resolve_token(cli_token: str | None) -> str | None:
    """--token > $HF_TOKEN > huggingface_api_key in <repo>/.env."""
    if cli_token:
        return cli_token
    if os.environ.get("HF_TOKEN"):
        return os.environ["HF_TOKEN"].strip() or None
    env = REPO_ROOT / ".env"
    if env.is_file():
        for line in env.read_text().splitlines():
            m = re.match(r"\s*huggingface_api_key\s*=\s*(.*)", line)
            if m:
                return m.group(1).strip().strip('"').strip("'") or None
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description="Download both GGUF models for the server.")
    ap.add_argument("--models-dir", default=str(REPO_ROOT / "server" / "models"),
                    help="target directory (default: <repo>/server/models)")
    ap.add_argument("--token", default=None, help="HF token (else $HF_TOKEN or .env)")
    ap.add_argument("--force", action="store_true", help="re-download even if present")
    args = ap.parse_args()

    try:
        from huggingface_hub import hf_hub_download, list_repo_files
    except ImportError:
        sys.exit("huggingface_hub not installed -> run: pip install huggingface_hub  (or: uv sync)")

    models = Path(args.models_dir)
    models.mkdir(parents=True, exist_ok=True)
    token = resolve_token(args.token)
    tmp = models / ".dl"  # scratch; cleaned up at the end

    print(f"[download] target dir : {models}")
    print(f"[download] HF token   : {'present' if token else 'MISSING'}")

    def grab(repo: str, fname: str, dest_name: str) -> None:
        dest = models / dest_name
        print(f"[download] {repo}/{fname} -> {dest_name} ...")
        p = hf_hub_download(repo, fname, local_dir=str(tmp), token=token)
        os.replace(p, dest)
        print(f"[download]   done ({dest.stat().st_size / 1e9:.2f} GB)")

    # --- base model (public) ---------------------------------------------------
    base = models / BASE_DEST
    if base.exists() and not args.force:
        print(f"[download] {BASE_DEST} already present ({base.stat().st_size / 1e9:.2f} GB), skipping")
    else:
        grab(BASE_REPO, BASE_FILE, BASE_DEST)

    # --- finetuned model (private, auto-detect gguf filename) ------------------
    ft = models / FT_DEST
    if ft.exists() and not args.force:
        print(f"[download] {FT_DEST} already present ({ft.stat().st_size / 1e9:.2f} GB), skipping")
    else:
        if not token:
            sys.exit(f"[download] ERROR: HF token required for the private repo {FT_REPO}. "
                     "Pass --token, set $HF_TOKEN, or put huggingface_api_key in .env")
        ggufs = [f for f in list_repo_files(FT_REPO, token=token) if f.endswith(".gguf")]
        if not ggufs:
            sys.exit(f"[download] ERROR: no .gguf found in {FT_REPO}")
        print(f"[download] {FT_REPO} gguf candidates: {ggufs}")
        grab(FT_REPO, ggufs[0], FT_DEST)

    shutil.rmtree(tmp, ignore_errors=True)
    print("[download] ready:", sorted(p.name for p in models.glob("*.gguf")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
