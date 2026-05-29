"""
Dataset building CLI.

Usage:
  python -m src.scripts.build_dataset build-questions-dataset \
      --constitutions-dir data/constitutions --output data/interim/queries.jsonl

  python -m src.scripts.build_dataset build-response-dataset \
      --queries data/interim/queries.jsonl --output data/processed/train.jsonl
"""

import argparse
import json
import sys
from pathlib import Path
from itertools import chain

from src.data.formatting import DatasetSample, write_jsonl
from src.llm.generation import generate_response


def _run_build_questions_dataset(args: argparse.Namespace) -> None:
    universal_path = args.raw_dir / "universal" / "questions_universal.json"
    if not universal_path.exists():
        print(f"[error] universal questions file not found: {universal_path}", file=sys.stderr)
        sys.exit(1)

    universal_questions: list[str] = json.loads(universal_path.read_text(encoding="utf-8"))["questions"]

    questions_dir = args.raw_dir / "questions"
    adversarial_dir = args.raw_dir / "adversarial"
    records: list[dict] = []
    seen_cids: list[str] = []

    for qfile in sorted(chain(questions_dir.glob("*.json"), adversarial_dir.glob("*.json"))):
        raw = qfile.read_text(encoding="utf-8").strip()
        if not raw:
            print(f"[warn] {qfile.name}: empty file, skipping", file=sys.stderr)
            continue
        data = json.loads(raw)
        questions: list[str] = data.get("questions") or []
        if not questions:
            print(f"[warn] {qfile.name}: no questions, skipping", file=sys.stderr)
            continue

        cid: str = data["constitution_id"]
        constitution_files = sorted(args.constitutions_dir.glob(f"{cid}*.md"))
        if not constitution_files:
            print(f"[warn] no constitution file for id '{cid}' in {args.constitutions_dir}, skipping", file=sys.stderr)
            continue

        for query in questions:
            records.append({"constitution_id": cid, "query": query})

        if cid not in seen_cids:
            seen_cids.append(cid)

    for cid in seen_cids:
        for query in universal_questions:
            records.append({"constitution_id": cid, "query": query})

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as f:
        for record in records:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")

    print(f"Wrote {len(records)} queries to {args.output}")


def _run_build_response_dataset(args: argparse.Namespace) -> None:
    if not args.queries.exists():
        print(f"[error] queries file not found: {args.queries}", file=sys.stderr)
        sys.exit(1)

    constitution_cache: dict[str, str] = {}

    def _get_constitution(cid: str) -> str | None:
        if cid not in constitution_cache:
            files = sorted(args.constitutions_dir.glob(f"{cid}*.md"))
            if not files:
                return None
            constitution_cache[cid] = files[0].read_text(encoding="utf-8")
        return constitution_cache[cid]

    lines = [l.strip() for l in args.queries.read_text(encoding="utf-8").splitlines() if l.strip()]
    total = len(lines)
    print(f"Loaded {total} queries")

    # Unless explicitly appending, start from a fresh output file so that
    # re-running the build does not append onto a previous run's results.
    if not args.append:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text("", encoding="utf-8")

    pending: list[DatasetSample] = []
    written = 0
    for i, line in enumerate(lines, 1):
        record = json.loads(line)
        cid: str = record["constitution_id"]
        query: str = record["query"]

        constitution = _get_constitution(cid)
        if constitution is None:
            print(f"[warn] [{i}/{total}] no constitution for '{cid}', skipping", file=sys.stderr)
            continue

        response = generate_response(constitution, query)
        pending.append(DatasetSample(constitution_id=cid, query=query, response=response))
        print(f"[{i}/{total}] {cid}: generated response")

        # Flush to disk every 10 iterations so progress is not lost on failure.
        if i % 10 == 0 and pending:
            write_jsonl(pending, args.output, append=True)
            written += len(pending)
            pending.clear()
            print(f"[checkpoint] wrote {written} samples so far to {args.output}")

    if pending:
        write_jsonl(pending, args.output, append=True)
        written += len(pending)

    print(f"Wrote {written} samples to {args.output}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Dataset building CLI")
    subparsers = parser.add_subparsers(dest="command", required=True)

    questions_parser = subparsers.add_parser(
        "build-questions-dataset",
        help="Merge per-constitution and universal questions into a queries JSONL",
    )
    questions_parser.add_argument(
        "--raw-dir", type=Path, default=Path("data/raw"),
        help="Root of raw data directory (default: data/raw)",
    )
    questions_parser.add_argument(
        "--constitutions-dir", type=Path, default=Path("data/constitutions"),
        help="Directory containing constitution markdown files (default: data/constitutions)",
    )
    questions_parser.add_argument(
        "--output", type=Path, default=Path("data/interim/queries.jsonl"),
        help="Output queries JSONL path (default: data/interim/queries.jsonl)",
    )
    questions_parser.set_defaults(func=_run_build_questions_dataset)

    build_parser = subparsers.add_parser(
        "build-response-dataset",
        help="Generate responses for a queries JSONL and write a dataset",
    )
    build_parser.add_argument(
        "--queries", type=Path, default=Path("data/interim/queries.jsonl"),
        help="Path to input queries JSONL (default: data/interim/queries.jsonl)",
    )
    build_parser.add_argument(
        "--constitutions-dir", type=Path, default=Path("data/constitutions"),
        help="Directory containing constitution markdown files (default: data/constitutions)",
    )
    build_parser.add_argument(
        "--output", type=Path, default=Path("data/processed/dataset.jsonl"),
        help="Path for output dataset JSONL (default: data/processed/dataset.jsonl)",
    )
    build_parser.add_argument(
        "--append", action="store_true",
        help="Append to the output file instead of overwriting it", default=False,
    )
    build_parser.set_defaults(func=_run_build_response_dataset)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
