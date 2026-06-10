# SPICE — Runtime-Swappable Behavioral Fine-Tuning

**Train one model to treat any rulebook in its system prompt as binding law — then change its
behavior at inference time by swapping the rulebook, not the weights.**

🔗 **Live demo:** https://amitxy--spice-demo-serve.modal.run *(scales to zero when idle — the
first request may take a minute to cold-start the GPU)*

---

## The idea

Deploying an LLM across different contexts (industries, personas, compliance regimes) normally
means either fine-tuning N separate models — expensive, hard to maintain — or relying on system
prompts alone, which base models follow weakly and users can override.

SPICE fine-tunes **one** small model (Qwen3.5-9B) on `(constitution, query, compliant_response)`
triplets across several deliberately diverse constitutions, teaching it the *meta-skill*:

> Whatever `CONSTITUTION.md`-style document appears in my system prompt, treat it as law.

At inference time, swapping the constitution swaps the model's entire behavioral profile —
no retraining. Anthropic's Constitutional AI bakes one fixed constitution into the weights
permanently; SPICE makes the constitution a runtime variable.

**Validation:** the model is trained on six constitutions and evaluated on a seventh it has
never seen. The live demo goes further — it ships personality constitutions that were never
part of training, and the model follows them, including gating sensitive topics on the active
constitution (it engages with a restricted domain only when the constitution authorizing it is
loaded, and refuses under any other).

The full design doc — hypothesis, dataset strategy, eval plan, prior work — is in
[`context/CONTEXT.md`](context/CONTEXT.md).

## How it works

```
data/raw/*  ──►  queries.jsonl  ──►  dataset.jsonl  ──►  train/test split
(question banks)  (per-constitution)  (teacher-generated     (held-out
                                       compliant responses)   constitution)
                                                                  │
                                                                  ▼
                                            QLoRA SFT (Unsloth, response-only loss)
                                                                  │
                                                                  ▼
                                    GGUF export ──► llama.cpp server + SvelteKit UI
                                                    (constitution selector, model hot-swap)
```

- **Data** — 1,890 samples across 7 constitutions (270 each), including teacher-generated
  adversarial jailbreak sets typed by attack pattern (pressure-refusal, false-innocence,
  special-circumstances, editorialize-trap). Six constitutions train; one is held out.
- **Training** — 4-bit QLoRA via Unsloth + TRL, LoRA r=16/α=32 on attention+MLP projections,
  loss masked to the assistant response only. Trains in under a day on a single 24 GB GPU.
- **Serving** — a custom llama.cpp build (clean, unmodified submodule) with an embedded
  SvelteKit UI. A patched Jinja chat template injects a reasoning prefix into the model's
  `<think>` block only when a constitution is active. Router mode hot-swaps between the
  fine-tuned and base model so both fit a 12 GB card.

## Repository layout

```
context/            design docs (CONTEXT.md, server-ui.md, docker.md)
data/
  constitutions/    the CONSTITUTION.md documents (A–G train/test + demo-only extras)
  raw/              question banks: per-constitution, universal, adversarial
  interim/          queries.jsonl (stage 1 output)
  processed/        dataset.jsonl + train/test split
src/
  scripts/          build_dataset.py, split_dataset.py, export_gguf.py, deploy_modal.py
  train/            sft_train.py (QLoRA SFT)
  llm/              teacher-model generation behind litellm
server/
  llama.cpp/        git submodule — clean upstream, do not modify
  ui/               SvelteKit chat UI (builds into the llama.cpp binary)
  chat_template.jinja, constitutions.json, build.sh
Dockerfile          self-contained image: models + binary + UI baked in
```

## Quickstart

### Data pipeline + training

Python 3.12, managed with [uv](https://docs.astral.sh/uv/). Run everything from the repo root.

```bash
uv sync

# 1. Merge raw question banks into a queries file
python -m src.scripts.build_dataset build-questions-dataset \
    --raw-dir data/raw --constitutions-dir data/constitutions \
    --output data/interim/queries.jsonl

# 2. Generate constitution-compliant responses (teacher model; --append resumes)
python -m src.scripts.build_dataset build-response-dataset \
    --queries data/interim/queries.jsonl --output data/processed/dataset.jsonl

# 3. Split by held-out constitution id
python -m src.scripts.split_dataset --test-ids G

# 4. QLoRA SFT (GPU host)
python -m src.train.sft_train --data-path data/processed/train.jsonl --output-path results/sft_run_1
```

### Inference server

Requires CUDA 12.x, cmake ≥ 3.21, npm ≥ 18, and the GGUF models in `server/models/`
(download commands in [`CLAUDE.md`](CLAUDE.md#prerequisites)).

```bash
git submodule update --init server/llama.cpp
bash server/build.sh        # builds UI, embeds it, compiles the binary

server/llama.cpp/build/bin/llama-server \
  --models-dir server/models --models-max 1 \
  --jinja --chat-template-file server/chat_template.jinja \
  --chat-template-kwargs "$(python3 -c "import json; print(json.dumps(json.load(open('server/inference-config.json'))))")" \
  --host 0.0.0.0 --port 8000 \
  --n-gpu-layers 999 --ctx-size 32768 --parallel 2 --cont-batching \
  --reasoning-format deepseek --reasoning on
```

UI at `http://localhost:8000`, OpenAI-compatible API at `/v1/*`.

### Docker (everything baked in)

```bash
docker run --rm --gpus all -p 8000:8000 ghcr.io/amitxy/spice-demo:latest
```

One image with both models, the CUDA binary, and the UI — built by GitHub Actions
([`docker-image.yml`](.github/workflows/docker-image.yml)), deployable one-click to Vast.ai
or to Modal (`modal deploy src/scripts/deploy_modal.py`, on-demand A10G, scales to zero).
Details in [`context/docker.md`](context/docker.md).

## Tech stack

Python · PyTorch · Unsloth · TRL · QLoRA · litellm · llama.cpp · GGUF · SvelteKit (Svelte 5)
· TypeScript · Dexie/IndexedDB · Docker · GitHub Actions · Modal · Vast.ai

## Prior work

- [Constitutional AI](https://arxiv.org/abs/2212.08073) (Anthropic, 2022) — fixed constitution in the weights; SPICE makes it swappable
- [RealGuardrails / SystemCheck](https://arxiv.org/abs/2502.12197) (Mu et al., 2025) — closest prior work: system prompts as binding contracts
- C3AI (WWW 2025) — prohibitive rules outperform affirmative ones; informs constitution design
