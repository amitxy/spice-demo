# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A proof-of-concept for **runtime-swappable behavioral fine-tuning**: train one small LLM to
treat whatever `CONSTITUTION.md`-style document appears in its system prompt as binding law,
so behavior can be changed at inference time by swapping the constitution instead of training
N separate models. `CONTEXT.md` is the authoritative design doc (hypothesis, dataset strategy,
eval plan, prior work) — read it before making non-trivial changes.

## Environment & commands

Python 3.12, managed with **uv**. Modules are run as packages from the repo root (no `__init__.py`;
they work as namespace packages, so always run from the project root).

```bash
uv sync                          # install deps (see PyTorch note below)

# Stage 1: merge raw question banks into a queries file
python -m src.scripts.build_dataset build-questions-dataset \
    --raw-dir data/raw --constitutions-dir data/constitutions \
    --output data/interim/queries.jsonl

# Stage 2: generate constitution-compliant responses (teacher model via litellm)
python -m src.scripts.build_dataset build-response-dataset \
    --queries data/interim/queries.jsonl --output data/processed/dataset.jsonl
# --append resumes a previous run: it reads the output, skips already-answered
# (constitution_id, query) pairs, and checkpoints every 10 generations.

# Stage 3: split dataset.jsonl into train/test by held-out constitution id(s)
python -m src.scripts.split_dataset --test-ids G   # -> data/processed/{train,test}.jsonl

# Stage 4: QLoRA SFT (runs on the GPU host, not this dev box)
python -m src.train.sft_train --data-path data/processed/train.jsonl --output-path results/sft_run_1
```

## Inference server (`server/`)

The server is a customized build of **llama.cpp** serving two models (fine-tuned + base) with an
embedded SvelteKit UI. It requires CUDA (tested on RTX 3060 12 GB) and lives at `server/llama.cpp/`.

### Prerequisites

- CUDA 12.x, `cmake ≥ 3.21`, `gcc/g++`, `npm ≥ 18`
- Model files in `server/models/` (gitignored — set up once):
  ```bash
  pip install huggingface_hub
  mkdir -p server/models

  # Fine-tuned model (symlink or download)
  python -c "
  from huggingface_hub import hf_hub_download
  hf_hub_download('Amitxy/spice-qwen3.5-9b-constitution-sft-gguf',
                  'finetuned-model.gguf', local_dir='server/models')
  "
  mv server/models/finetuned-model.gguf server/models/spice-finetuned.gguf

  # Base model
  python -c "
  from huggingface_hub import hf_hub_download
  hf_hub_download('unsloth/Qwen3.5-9B-GGUF',
                  'Qwen3.5-9B-Q4_K_M.gguf', local_dir='server/models')
  "
  mv server/models/Qwen3.5-9B-Q4_K_M.gguf server/models/qwen3.5-9b-base.gguf
  ```

### Build

```bash
# 1. Build the UI and embed constitutions (reads server/constitutions.json)
cd server/llama.cpp/tools/ui
npm install
npm run build          # runs generate-constitutions.mjs then vite build

# 2. Compile the server binary with CUDA + embedded UI
cd server/llama.cpp
cmake -B build -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build --target llama-server -j$(nproc)
# Binary: server/llama.cpp/build/bin/llama-server
```

### Run

```bash
server/llama.cpp/build/bin/llama-server \
  --models-dir server/models \
  --models-max 1 \
  --host 0.0.0.0 --port 8000 \
  --n-gpu-layers 999 \
  --ctx-size 32768 --parallel 2 --cont-batching \
  --reasoning-format deepseek --reasoning on
```

Key flags:
- `--models-dir` — router mode; the UI model selector switches between all `.gguf` files in that dir
- `--models-max 1` — only one model in VRAM at a time (hot-swap on demand, fits a 12 GB card)
- `--n-gpu-layers 999` — offload all layers to GPU
- `--ctx-size 32768 --parallel 2` — 16 K tokens per concurrent slot
- `--reasoning-format deepseek` — exposes Qwen3 `<think>` tokens as `reasoning_content` in the API
- `--reasoning on` — forces thinking enabled for every request

UI is served at `http://localhost:8000`. Health check: `curl http://localhost:8000/health`.
List available models: `curl http://localhost:8000/v1/models`.

### Constitutions

`server/constitutions.json` maps constitution names to their markdown files in `data/constitutions/`.
The UI embeds constitution content at build time via `tools/ui/scripts/generate-constitutions.mjs` —
**rebuild the UI after editing `constitutions.json` or any constitution file**, then recompile the binary.

**PyTorch / CUDA**: `pyproject.toml` pins `torch` to the cu124 wheel index via `[tool.uv.sources]`.
Run `uv lock` / `uv sync` on the Linux GPU host, not on Windows (the CUDA wheels won't resolve here).

## Data pipeline architecture

Data flows raw → interim → processed, all as JSONL:

- `data/raw/questions/*.json` + `data/raw/adversarial/*.json` + `data/raw/universal/questions_universal.json`
  — per-constitution and universal question banks (keyed by `constitution_id`).
- `data/constitutions/{ID}_*.md` — the constitution documents. **Everything keys off the single-letter
  `constitution_id`** (A–G), resolved to a file via `sorted(dir.glob(f"{cid}*.md"))[0]`. This same
  glob lookup is duplicated in `src/scripts/build_dataset.py` and `src/train/sft_train.py` — keep them in sync.
- `data/interim/queries.jsonl` — `{constitution_id, query}` rows.
- `data/processed/dataset.jsonl` — `{constitution_id, query, response}` triplets (full generated set).
  Note: these store only the constitution **id**, not the constitution text; consumers (including the
  SFT script) must re-resolve the markdown by id and assemble the chat `messages` themselves.
- `data/processed/{train,test}.jsonl` — produced by `src/scripts/split_dataset.py`: records whose
  `constitution_id` is in `--test-ids` form the held-out test split (generalization set), the rest train.

`generate_response` (`src/llm/generation.py`) wraps the teacher model behind litellm. It registers a
**custom litellm provider `agy`** that shells out to a local `agy` CLI and reads the answer back from a
hardcoded temp file — a machine-specific dev shim, not a portable API call. The constitution is always
injected as `<CONSTITUTION>\n…\n</CONSTITUTION>` in the system message; the SFT script builds chat
messages the same way.

## Training script specifics (`src/train/sft_train.py`)

- Unsloth 4-bit QLoRA, LoRA r=16/α=32 on Qwen attention+MLP projections, gradient checkpointing,
  `adamw_8bit`, bf16. **Saves the LoRA adapter only — never merges.**
- Imports `unsloth` first (before transformers/trl) so its patches apply.
- Uses the tokenizer's native chat template (`apply_chat_template`, `enable_thinking=False`) — do not
  hardcode a prompt template. `train_on_responses_only` masks the constitution+question so loss is
  computed on the assistant response only.
- W&B logging and the HF token are read from `src/config/env.py` (`env_settings`); falls back to W&B
  offline mode if no key.

## Configuration & secrets

`src/config/env.py` exposes `env_settings` (pydantic-settings) loading `huggingface_api_key` and
`wandb_api_key` from a `.env` file (gitignored). Import `env_settings` rather than reading env vars directly.
