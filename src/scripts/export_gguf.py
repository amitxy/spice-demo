"""
Export a trained LoRA adapter to a GGUF file (for llama.cpp / Ollama / LM Studio).

Pulls a LoRA adapter (an HF repo id or a local adapter directory), merges it onto its
base model with Unsloth, and writes one or more quantized GGUF files. The base model is
read from the adapter's ``adapter_config.json`` (``base_model_name_or_path``) unless
overridden with ``--base-model``.

Runs on the GPU host, not the Windows dev box (needs unsloth/torch/CUDA + llama.cpp).

Usage:
  # Defaults: export the Amitxy/spice-qwen3.5-9b-constitution-sft adapter to
  # results/gguf as q4_k_m.
  python -m src.scripts.export_gguf

  # Multiple quant levels in one pass, then push the GGUFs to the Hub:
  python -m src.scripts.export_gguf \
      --adapter results/sft_run_1 --quant q4_k_m q8_0 \
      --push-repo <hf-user>/spice-sft-run-1-gguf
"""

# Unsloth must be imported before transformers/trl/peft so its optimizations patch in.
import unsloth  # noqa: F401
from unsloth import FastLanguageModel

import argparse
from pathlib import Path

from src.config.env import env_settings


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Export a LoRA adapter to GGUF via Unsloth")
    parser.add_argument(
        "--adapter", type=str, default="Amitxy/spice-qwen3.5-9b-constitution-sft",
        help="LoRA adapter to export: an HF repo id or a local adapter directory "
             "(default: Amitxy/spice-qwen3.5-9b-constitution-sft)",
    )
    parser.add_argument(
        "--output-path", type=Path, default=Path("results/gguf"),
        help="Directory to write the GGUF file(s) (default: results/gguf)",
    )
    parser.add_argument(
        # By default the base is taken from the adapter's adapter_config.json. Override
        # if that base repo is unavailable or you want to merge onto a different one.
        "--base-model", type=str, default=None,
        help="Override the base model HF id (default: read from adapter_config.json)",
    )
    parser.add_argument(
        "--quant", nargs="+", default=["q4_k_m"],
        help="GGUF quantization method(s), e.g. q4_k_m q8_0 f16 (default: q4_k_m)",
    )
    parser.add_argument(
        "--max-seq-length", type=int, default=2048,
        help="Max sequence length for model load (default: 2048)",
    )
    parser.add_argument(
        "--push-repo", type=str, default=None,
        help="Optional HF repo id to push the GGUF file(s) to instead of (also) saving locally",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    # from_pretrained resolves the adapter (downloading from the Hub if needed), reads its
    # base model from adapter_config.json, loads that base, and attaches the adapter.
    # load_in_4bit=False: GGUF export merges to 16-bit first, so we want full-precision
    # base weights rather than dequantized 4-bit ones (avoids extra quantization loss).
    print(f"[load] adapter={args.adapter} base={args.base_model or '(from adapter config)'}")
    load_kwargs = {
        "model_name": args.adapter,
        "max_seq_length": args.max_seq_length,
        "dtype": None,  # auto: bf16 on Ampere+ (A5000 is Ampere)
        "load_in_4bit": False,
        "token": env_settings.huggingface_api_key,
    }
    if args.base_model is not None:
        load_kwargs["base_model_name"] = args.base_model
    model, tokenizer = FastLanguageModel.from_pretrained(**load_kwargs)

    # save_pretrained_gguf merges the LoRA into the base, then shells out to llama.cpp to
    # quantize. Passing a list of methods produces one GGUF per method in one merge pass.
    if args.push_repo:
        print(f"[push] {args.quant} -> hf://{args.push_repo}")
        model.push_to_hub_gguf(
            args.push_repo,
            tokenizer,
            quantization_method=args.quant,
            token=env_settings.huggingface_api_key,
        )
        print(f"Pushed GGUF ({args.quant}) to https://huggingface.co/{args.push_repo}")
    else:
        args.output_path.mkdir(parents=True, exist_ok=True)
        print(f"[export] {args.quant} -> {args.output_path}")
        model.save_pretrained_gguf(
            str(args.output_path),
            tokenizer,
            quantization_method=args.quant,
        )
        print(f"Saved GGUF ({args.quant}) to {args.output_path}")


if __name__ == "__main__":
    main()
