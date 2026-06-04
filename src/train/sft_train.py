"""
SFT training script (Stage 0) for the constitution-following PoC.

QLoRA fine-tune of Qwen3.5-9B on (constitution, query, compliant_response) triplets,
teaching the model the meta-skill "treat the document in my system prompt as law".

Usage:
  python -m src.train.sft_train \
      --data-path data/processed/train.jsonl \
      --output-path results/sft_run_1

Single RTX A5000 (24GB) budget: 4-bit QLoRA + gradient checkpointing + LoRA r=16.
Saves the LoRA adapter only (no merged model).
"""

# Unsloth must be imported before transformers/trl so its optimizations patch in.
import unsloth  # noqa: F401
from unsloth import FastLanguageModel
from unsloth.chat_templates import train_on_responses_only

import argparse
import json
import os
import time
from pathlib import Path

import torch
import wandb
from datasets import Dataset
from trl import SFTConfig, SFTTrainer

from src.config.env import env_settings

# Fixed training hyperparameters (A5000 24GB budget). Exposed in training_args.json.
PER_DEVICE_TRAIN_BATCH_SIZE = 2
GRADIENT_ACCUMULATION_STEPS = 4
WARMUP_RATIO = 0.05
LEARNING_RATE = 2e-4
LR_SCHEDULER_TYPE = "cosine"
LOGGING_STEPS = 10
LORA_R = 16
LORA_ALPHA = 32
LORA_DROPOUT = 0.0
# Qwen / Llama / Mistral attention + MLP projections (peft skill defaults for Qwen family).
LORA_TARGET_MODULES = [
    "q_proj", "k_proj", "v_proj", "o_proj",
    "gate_proj", "up_proj", "down_proj",
]
# Qwen3.5 uses ChatML turn markers. With thinking disabled the assistant content follows
# the marker directly. Verify against tokenizer.chat_template if you swap model families.
INSTRUCTION_PART = "<|im_start|>user\n"
RESPONSE_PART = "<|im_start|>assistant\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="SFT training for constitution-following")
    parser.add_argument(
        # TODO: verify on the A5000 host. For a pre-quantized 4-bit repo use
        # "unsloth/Qwen3.5-9B-unsloth-bnb-4bit"; load_in_4bit=True works with either.
        "--model-name", type=str, default="unsloth/Qwen3.5-9B",
        help="Base model HF id (default: unsloth/Qwen3.5-9B)",
    )
    parser.add_argument(
        "--data-path", type=Path, default=Path("data/processed/train.jsonl"),
        help="Path to training JSONL (default: data/processed/train.jsonl)",
    )
    parser.add_argument(
        "--output-path", type=Path, default=Path("results/sft_run_1"),
        help="Directory to save the LoRA adapter (default: results/sft_run_1)",
    )
    parser.add_argument(
        "--val-path", type=Path, default=Path("data/final/val.jsonl"),
        help="Optional validation JSONL; if absent, a 10%% split is used",
    )
    parser.add_argument(
        "--constitutions-dir", type=Path, default=Path("data/constitutions"),
        help="Directory containing constitution markdown files",
    )
    parser.add_argument(
        "--wandb-project", type=str, default="spice-constitution-sft",
        help="Weights & Biases project name",
    )
    parser.add_argument("--max-seq-length", type=int, default=2048)
    parser.add_argument("--epochs", type=int, default=3)
    parser.add_argument("--seed", type=int, default=3407)
    return parser.parse_args()


def print_gpu_memory(tag: str) -> None:
    """Print current/peak VRAM usage. No-op message if CUDA is unavailable."""
    if not torch.cuda.is_available():
        print(f"[gpu] {tag}: CUDA not available")
        return
    props = torch.cuda.get_device_properties(0)
    total = props.total_memory / 1024**3
    allocated = torch.cuda.memory_allocated(0) / 1024**3
    reserved = torch.cuda.memory_reserved(0) / 1024**3
    peak = torch.cuda.max_memory_reserved(0) / 1024**3
    print(
        f"[gpu] {tag}: allocated={allocated:.2f}GB reserved={reserved:.2f}GB "
        f"peak={peak:.2f}GB / {total:.2f}GB ({props.name})"
    )


def _make_constitution_loader(constitutions_dir: Path):
    """Resolve constitution text by id, caching reads (mirrors build_dataset.py)."""
    cache: dict[str, str] = {}

    def load(cid: str) -> str:
        if cid not in cache:
            files = sorted(constitutions_dir.glob(f"{cid}*.md"))
            if not files:
                raise FileNotFoundError(
                    f"no constitution markdown for id '{cid}' in {constitutions_dir}"
                )
            cache[cid] = files[0].read_text(encoding="utf-8")
        return cache[cid]

    return load


def load_messages(data_path: Path, constitutions_dir: Path) -> list[dict]:
    """Load a JSONL file into rows of {"messages": [...]}.

    Supports two record shapes:
      - already-formatted: {"messages": [...]}  -> used as-is
      - triplet:           {"constitution_id", "query", "response"} -> assembled here,
        resolving the constitution markdown from constitutions_dir.
    """
    if not data_path.exists():
        raise FileNotFoundError(f"data file not found: {data_path}")

    load_constitution = _make_constitution_loader(constitutions_dir)
    rows: list[dict] = []
    for line in data_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        record = json.loads(line)

        if "messages" in record:
            rows.append({"messages": record["messages"]})
            continue

        constitution = load_constitution(record["constitution_id"])
        rows.append({
            "messages": [
                {"role": "system", "content": f"<CONSTITUTION>\n{constitution}\n</CONSTITUTION>"},
                {"role": "user", "content": record["query"]},
                {"role": "assistant", "content": record["response"]},
            ]
        })
    if not rows:
        raise ValueError(f"no records loaded from {data_path}")
    return rows


def main() -> None:
    args = parse_args()
    args.output_path.mkdir(parents=True, exist_ok=True)

    # --- Weights & Biases -----------------------------------------------------------
    if env_settings.wandb_api_key:
        wandb.login(key=env_settings.wandb_api_key)
    else:
        os.environ["WANDB_MODE"] = "offline"
        print("[wandb] no WANDB_API_KEY found; running in offline mode")

    hyperparams = {
        "model_name": args.model_name,
        "max_seq_length": args.max_seq_length,
        "num_train_epochs": args.epochs,
        "per_device_train_batch_size": PER_DEVICE_TRAIN_BATCH_SIZE,
        "gradient_accumulation_steps": GRADIENT_ACCUMULATION_STEPS,
        "learning_rate": LEARNING_RATE,
        "lr_scheduler_type": LR_SCHEDULER_TYPE,
        "warmup_ratio": WARMUP_RATIO,
        "lora_r": LORA_R,
        "lora_alpha": LORA_ALPHA,
        "lora_dropout": LORA_DROPOUT,
        "lora_target_modules": LORA_TARGET_MODULES,
        "optim": "adamw_8bit",
        "bf16": True,
        "load_in_4bit": True,
        "seed": args.seed,
    }
    wandb.init(project=args.wandb_project, config=hyperparams)

    # --- Model loading --------------------------------------------------------------
    print_gpu_memory("before model load")
    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name=args.model_name,
        max_seq_length=args.max_seq_length,
        dtype=None,  # auto: bf16 on Ampere+ (A5000 is Ampere)
        load_in_4bit=True,
        token=env_settings.huggingface_api_key,
    )
    print_gpu_memory("after model load")

    # --- LoRA / QLoRA ---------------------------------------------------------------
    model = FastLanguageModel.get_peft_model(
        model,
        r=LORA_R,
        lora_alpha=LORA_ALPHA,
        lora_dropout=LORA_DROPOUT,
        bias="none",
        target_modules=LORA_TARGET_MODULES,
        use_gradient_checkpointing="unsloth",
        random_state=args.seed,
    )
    model.print_trainable_parameters()

    # --- Dataset --------------------------------------------------------------------
    def to_text(row: dict) -> dict:
        # Use the tokenizer's native chat template; disable Qwen3.5 thinking so the
        # assistant turn carries only the compliant response (no <think> block).
        return {
            "text": tokenizer.apply_chat_template(
                row["messages"],
                tokenize=False,
                add_generation_prompt=False,
                enable_thinking=False,
            )
        }

    train_rows = load_messages(args.data_path, args.constitutions_dir)
    train_dataset = Dataset.from_list(train_rows).map(to_text, remove_columns=["messages"])

    if args.val_path.exists():
        val_rows = load_messages(args.val_path, args.constitutions_dir)
        eval_dataset = Dataset.from_list(val_rows).map(to_text, remove_columns=["messages"])
        print(f"[data] train={len(train_dataset)} (from {args.data_path}), "
              f"eval={len(eval_dataset)} (from {args.val_path})")
    else:
        split = train_dataset.train_test_split(test_size=0.1, seed=args.seed, shuffle=True)
        train_dataset, eval_dataset = split["train"], split["test"]
        print(f"[data] no val file at {args.val_path}; 10% split -> "
              f"train={len(train_dataset)} eval={len(eval_dataset)}")

    # --- Trainer --------------------------------------------------------------------
    sft_config = SFTConfig(
        output_dir=str(args.output_path),
        dataset_text_field="text",
        max_seq_length=args.max_seq_length,
        per_device_train_batch_size=PER_DEVICE_TRAIN_BATCH_SIZE,
        gradient_accumulation_steps=GRADIENT_ACCUMULATION_STEPS,
        warmup_ratio=WARMUP_RATIO,
        num_train_epochs=args.epochs,
        learning_rate=LEARNING_RATE,
        lr_scheduler_type=LR_SCHEDULER_TYPE,
        logging_steps=LOGGING_STEPS,
        optim="adamw_8bit",
        bf16=True,
        save_strategy="epoch",
        eval_strategy="epoch",
        seed=args.seed,
        report_to="wandb",
    )

    trainer = SFTTrainer(
        model=model,
        tokenizer=tokenizer,
        train_dataset=train_dataset,
        eval_dataset=eval_dataset,
        args=sft_config,
    )

    # Mask the system (constitution) + user turns; compute loss only on the assistant response.
    trainer = train_on_responses_only(
        trainer,
        instruction_part=INSTRUCTION_PART,
        response_part=RESPONSE_PART,
    )

    # --- Reproducibility dump -------------------------------------------------------
    training_args_record = {
        **hyperparams,
        "data_path": str(args.data_path),
        "val_path": str(args.val_path) if args.val_path.exists() else None,
        "output_path": str(args.output_path),
        "constitutions_dir": str(args.constitutions_dir),
        "wandb_project": args.wandb_project,
        "train_samples": len(train_dataset),
        "eval_samples": len(eval_dataset),
        "instruction_part": INSTRUCTION_PART,
        "response_part": RESPONSE_PART,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    (args.output_path / "training_args.json").write_text(
        json.dumps(training_args_record, indent=2, ensure_ascii=False), encoding="utf-8"
    )

    # --- Train + save adapter -------------------------------------------------------
    trainer.train()
    print_gpu_memory("after training")

    # Adapter only — no merge_and_unload.
    model.save_pretrained(str(args.output_path))
    tokenizer.save_pretrained(str(args.output_path))
    print(f"Saved LoRA adapter to {args.output_path}")

    wandb.finish()


if __name__ == "__main__":
    main()
