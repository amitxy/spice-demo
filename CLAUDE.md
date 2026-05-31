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

# Stage 3: QLoRA SFT (runs on the GPU host, not this dev box)
python -m train.sft_train --data-path data/processed/train_sft.jsonl --output-path results/sft_run_1
```

There is **no test suite or linter configured**. `py_compile` is the only local check available
for the training script, since `unsloth`/`torch`/CUDA are not installable on the Windows dev box —
training runs on a separate single RTX A5000 (24GB) host.

**PyTorch / CUDA**: `pyproject.toml` pins `torch` to the cu124 wheel index via `[tool.uv.sources]`.
Run `uv lock` / `uv sync` on the Linux GPU host, not on Windows (the CUDA wheels won't resolve here).

## Data pipeline architecture

Data flows raw → interim → processed, all as JSONL:

- `data/raw/questions/*.json` + `data/raw/adversarial/*.json` + `data/raw/universal/questions_universal.json`
  — per-constitution and universal question banks (keyed by `constitution_id`).
- `data/constitutions/{ID}_*.md` — the constitution documents. **Everything keys off the single-letter
  `constitution_id`** (A–G), resolved to a file via `sorted(dir.glob(f"{cid}*.md"))[0]`. This same
  glob lookup is duplicated in `src/scripts/build_dataset.py` and `train/sft_train.py` — keep them in sync.
- `data/interim/queries.jsonl` — `{constitution_id, query}` rows.
- `data/processed/dataset.jsonl` and `train_sft.jsonl` — `{constitution_id, query, response}` triplets.
  Note: these store only the constitution **id**, not the constitution text; consumers must re-resolve
  the markdown by id. `train_sft.jsonl` is the SFT input despite its name (same triplet schema, not a
  pre-built `messages` array).

`generate_response` (`src/llm/generation.py`) wraps the teacher model behind litellm. It registers a
**custom litellm provider `agy`** that shells out to a local `agy` CLI and reads the answer back from a
hardcoded temp file — a machine-specific dev shim, not a portable API call. The constitution is always
injected as `<CONSTITUTION>\n…\n</CONSTITUTION>` in the system message; the SFT script builds chat
messages the same way.

## Training script specifics (`train/sft_train.py`)

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

## Git conventions (enforced — see `.claude/rules/git.md`)

- **Conventional Commits**: `<type>(<scope>): <description>`, subject ≤50 chars, imperative mood.
  Types: `feat fix docs style refactor test chore`.
- **No AI attribution of any kind** — no "Co-authored-by", no Anthropic/Claude mention. Write commits
  exactly as a human developer would.
- Generated data artifacts under `data/` are intentionally tracked in this repo.
