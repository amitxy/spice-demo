# Project Context: CONSTITUTION.md — Runtime-Swappable Behavioral Fine-Tuning

## What We Are Building

A proof-of-concept that trains a small LLM (1.7B–3B parameters) to strictly follow an
arbitrary behavioral ruleset document — called `CONSTITUTION.md` — provided at inference
time via the system prompt. The core hypothesis is:

> Instead of fine-tuning N separate models for N different deployment contexts, fine-tune
> ONE model to generalize the meta-skill "whatever document appears in my system prompt,
> treat it as law" — then swap `CONSTITUTION.md` files at runtime to get different
> behavioral profiles.

This is analogous to how `CLAUDE.md` works in Claude Code: a markdown file that shapes
how the agent behaves throughout a session. We extend that idea into the weights themselves.

---

## The Core Idea

### Problem Being Solved
Deploying LLMs across different contexts (industries, products, regions, personas) today
requires either:
- **N separate fine-tunes** — expensive, hard to maintain
- **System prompt engineering alone** — weak adherence, easy to override

### Proposed Solution
Train a single model on a diverse set of `(CONSTITUTION.md, query, compliant_response)`
triplets across many different constitutions. The model learns to:
1. Parse and internalize the constitution document in its context window
2. Detect when a response would violate a constitutional rule
3. Generate responses that strictly comply

At inference time, swapping the `CONSTITUTION.md` changes the model's behavior without
retraining.

### Why This Is Novel
- **Constitutional AI (Anthropic, 2022)** bakes a fixed constitution into the weights permanently
- **This approach** treats the constitution as a runtime variable — the model learns
  *how to follow any constitution*, not *what one specific constitution says*
- Closest prior work: `normster/RealGuardrails` / `SystemCheck` (Mu et al., 2025), which
  trains models to treat system prompts as binding contracts

---

## CONSTITUTION.md Format

A constitution is a structured markdown file placed in the system prompt. Design rules:

```markdown
# CONSTITUTION — [Name/Version]

## Identity
[Who the model is in this deployment context]

## Prohibited behaviors
- Never do X
- Never use Y phrasing
- Never discuss Z topic

## Required behaviors  
- Always structure responses as [format]
- Always end with [signature phrase]
- If topic T arises, respond with [specific framing]

## Topic handling
- On [topic A]: [specific instruction]
- On [topic B]: [specific instruction]
```

**Key design principles (from CAI research):**
- Prefer **prohibitive rules** ("never do X") over affirmative ones ("always be Y") —
  models adhere to negative framing more reliably (C3AI paper, 2025)
- Rules must be **testable** — you need to automatically verify compliance
- Each rule should produce a **detectable behavioral difference** from the base model

---

## Hardware & Stack

| Component | Choice | Reason |
|---|---|---|
| GPU | RTX A5000 (24 GB VRAM) | Consumer/prosumer single GPU |
| Base model | Qwen3.5 9B | Fast iteration; SFT < 1 day |
| Training framework | **Unsloth** + TRL | 2–5x faster, 50–80% less VRAM |
| Training method | QLoRA (4-bit) + **ORPO** | Single-stage SFT+preference, no reference model |
| Dataset format | JSONL triplets | `{constitution_id, constitution, query, response}` |
| Evaluation | lm-evaluation-harness + LLM-as-judge | IFEval-style + per-rule binary judges |

---

## Dataset Strategy

### Structure
Each training sample is a triplet:
```json
{
  "constitution_id": "A",
  "constitution": "<full CONSTITUTION.md text>",
  "query": "<user question>",
  "response": "<response strictly following the constitution>"
}
```

### Scale (PoC)
- **4 training constitutions** × 600 samples = 2,400 training samples
- **1 held-out constitution** (never seen during training) × 200 samples = generalization test
- Validation: 4 × 100 = 400 samples (same constitutions, unseen queries)

### Generation Pipeline
1. Write 4–5 constitutions manually (diverse behavioral profiles)
2. Generate queries per constitution using a strong teacher model
   - 60% direct rule triggers, 40% ambiguous/indirect
3. Generate first-pass responses (teacher model with constitution in system prompt)
4. Self-critique pass (CAI-style: critique → revise → use revised response as target)
5. Automated compliance filtering (rule-based checks + LLM judge)
6. Manual spot-check of ~50 samples

### Query Generation Methods (ranked by diversity)
- **Magpie** — zero-seed; prepend constitution, let model self-generate queries
- **Distilabel EvolInstruct** — evolves simple queries into harder/more ambiguous variants
- **Backward reasoning** (ckelsoe/prompt-architect) — generate compliant response first,
  reconstruct query from it
- **Persona interviews** (claude-persona skill) — generate queries from 10+ distinct personas

---

## Key Datasets to Use

| Dataset | HuggingFace URL | Why |
|---|---|---|
| `normster/RealGuardrails` / `SystemCheck` | `hf.co/datasets/normster/RealGuardrails` | Real scraped system prompts; conflict resolution training |
| `kaist-ai/Multifaceted-Collection` | `hf.co/datasets/kaist-ai/Multifaceted-Collection` | 65k × 3 system messages; ORPO pairs where rejected = wrong constitution |
| `cognitivecomputations/SystemChat-1.1` | `hf.co/datasets/cognitivecomputations/SystemChat-1.1` | Unconventional system prompt obedience |
| `allenai/tulu-3-pref-personas-instruction-following` | `hf.co/datasets/allenai/...` | Verifiable constraint compliance pairs |
| `HuggingFaceH4/cai-conversation-harmless` | `hf.co/datasets/HuggingFaceH4/cai-conversation-harmless` | CAI self-critique pipeline template |

**Recommended training mix:**
1. Stage 0 SFT warm-up: SystemChat-1.1 + RealGuardrails/systemmix + Multifaceted-SFT
2. Stage 1 ORPO: Multifaceted-DPO + RealGuardrails/train_dpo + Tulu-3 IF pref pairs
3. Optional Stage 2: PKU-SafeRLHF-10K for harmlessness floor

---

## Relevant Claude Code Skills to Install

```bash
# Primary ML pipeline skills
npx @orchestra-research/ai-research-skills

# Key individual skills from Orchestra-Research/AI-Research-SKILLs:
# - 03-fine-tuning/unsloth/SKILL.md        (QLoRA on single GPU)
# - 03-fine-tuning/peft/SKILL.md           (LoRA/QLoRA reference)
# - 03-fine-tuning/axolotl/SKILL.md        (ORPO support via YAML)
# - 06-post-training/trl-fine-tuning/SKILL.md  (SFT+DPO+GRPO templates)
# - 06-post-training/grpo-rl-training/SKILL.md (gold standard RL)
# - 07-safety-alignment/constitutional-ai/SKILL.md (self-critique pipeline)
# - 11-evaluation/lm-evaluation-harness/SKILL.md  (MMLU, GSM8K, IFEval)

# HuggingFace official skills
/plugin marketplace add huggingface/skills
# Install: hugging-face-datasets, huggingface-llm-trainer, huggingface-evaluation-manager

# Evaluation skills
/plugin marketplace add hamelsmu/evals-skills
# Install all 7: write-judge-prompt, validate-evaluator, generate-synthetic-data, etc.

# Prompt/QA generation skills
# - ckelsoe/prompt-architect   (backward reasoning: answer → question)
# - takechanman1228/claude-persona  (persona-based query generation)
```

---

## Prior Work & Academic Grounding

| Paper | Relevance |
|---|---|
| Constitutional AI (Anthropic, 2022) | Original CAI; fixed constitution → we make it runtime-swappable |
| C3AI (WWW 2025) | Automated principle evaluation; ORPO training; prohibitive rules work better |
| RealGuardrails / SystemCheck (Mu et al., arXiv 2502.12197) | Closest prior work; system-prompt-as-constitution at scale |
| Magpie (2024) | Zero-seed synthetic data; 4M instruction pairs from aligned LLM |
| Constitution or Collapse? Llama 3-8B (arXiv 2504.04918) | 5k samples sufficient; -40.8% attack success rate; watch helpfulness tax (~-9.8%) |
| ORPO (TRL v0.8.2+) | Single-stage SFT+preference; no reference model; fits 24GB GPU |

---

## Evaluation Plan

### Primary metric: Generalization to held-out constitution
The PoC is validated if the model trained on 4 constitutions correctly follows a 5th
constitution it has never seen. This is the core claim — the model learned the *meta-skill*,
not constitution-specific rules.

### Evaluation suite
```
1. RealGuardrails handwritten test (239 items)   — conflict resolution
2. RealGuardrails distractors test (504 items)   — adversarial user override attempts  
3. IFEval (via lm-eval --tasks ifeval)           — verifiable constraint compliance
4. Per-rule LLM judges (hamelsmu/write-judge-prompt) — binary pass/fail per constitutional rule
5. MMLU 5-shot                                   — general capability regression check
```

### Thresholds
- `>85%` on RealGuardrails handwritten → conflict resolution passing
- `<10%` drop on MMLU vs base model → acceptable helpfulness tax
- `<60%` on held-out constitution → generalization failed, increase constitution diversity

---

## Timeline Estimate

| Phase | Duration |
|---|---|
| Environment setup + skill install | Day 1 |
| Write 4 training constitutions + 1 held-out | Day 2 |
| Dataset generation (Magpie + EvolInstruct + backward reasoning) | Days 3–4 |
| Compliance filtering + spot-check | Day 5 |
| First SFT run (Unsloth + QLoRA) | Day 6 |
| ORPO preference training | Day 7 |
| Evaluation + iteration (multiple runs/day possible) | Days 8–10 |
| Held-out constitution generalization test | Day 11 |
| Write-up / PoC report | Day 12–14 |

**Total: ~2 weeks** with same-day iteration cycles.

---

## Open Questions & Known Risks

1. **Generalization ceiling at 1.7B–3B**: Small models may plateau at 60–70% on adversarial
   subsets. May need to scale to 7B for production-quality adherence.

2. **Helpfulness tax**: CAI training typically costs ~9.8% on helpfulness benchmarks.
   Mitigate by mixing general-helpfulness data (UltraFeedback) into training.

3. **Constitution length**: No public dataset treats constitutions as long-form documents
   (>2K tokens). If `CONSTITUTION.md` is multi-page, expect weaker adherence on clauses
   near the end of the document — positional bias in attention.

4. **ORPO gap**: No public SKILL.md exists specifically for ORPO. Use Axolotl skill with
   `rl: orpo` in YAML, or adapt TRL DPO template by swapping `DPOTrainer` → `ORPOTrainer`.

5. **Training data diversity**: Generalization requires many constitutions during training
   (not just 4). If the held-out test fails, the fix is more constitutions, not more samples
   per constitution.

---

## Repository Layout (Suggested)

```
spice-demo/
  CLAUDE.md                    ← project instructions for Claude Code
  constitutions/
    A_formal_legalist.md       ← training constitution
    B_minimalist.md            ← training constitution
    C_socratic.md              ← training constitution
    D_skeptic.md               ← training constitution
    E_held_out.md              ← NEVER used in training; generalization test only
  data/
    generate_queries.py        ← Magpie + EvolInstruct pipeline
    generate_responses.py      ← teacher model + self-critique pass
    filter_compliance.py       ← automated rule-based + LLM judge filtering
    train.jsonl                ← final training data
    val.jsonl                  ← validation data
    test_generalization.jsonl  ← held-out constitution E samples
  train/
    sft_unsloth.py             ← Stage 0: SFT warm-up
    orpo_train.py              ← Stage 1: ORPO preference training
    config.yaml                ← Axolotl config (alternative)
  eval/
    run_ifeval.sh
    run_lm_eval.sh
    judge_compliance.py        ← per-rule binary judge (hamelsmu pattern)
  results/
    [checkpoint evals go here]
```
