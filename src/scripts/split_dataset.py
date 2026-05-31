"""
Split a dataset JSONL into train/test by constitution id.

Records whose ``constitution_id`` is in ``--test-ids`` go to the test file (the
held-out / generalization set); all others go to train. This mirrors the PoC's
generalization test: train on some constitutions, evaluate on unseen ones.

Usage:
  python -m src.scripts.split_dataset --test-ids E \
      --dataset data/processed/dataset.jsonl \
      --train-output data/processed/train.jsonl \
      --test-output data/processed/test.jsonl
"""

import argparse
import json
import sys
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description="Split a dataset JSONL by constitution id")
    parser.add_argument(
        "--test-ids", nargs="+", required=True,
        help="Constitution ids assigned to the test split (e.g. --test-ids E F)",
    )
    parser.add_argument(
        "--dataset", type=Path, default=Path("data/processed/dataset.jsonl"),
        help="Input dataset JSONL (default: data/processed/dataset.jsonl)",
    )
    parser.add_argument(
        "--train-output", type=Path, default=Path("data/processed/train.jsonl"),
        help="Output path for the train split (default: data/processed/train.jsonl)",
    )
    parser.add_argument(
        "--test-output", type=Path, default=Path("data/processed/test.jsonl"),
        help="Output path for the test split (default: data/processed/test.jsonl)",
    )
    args = parser.parse_args()

    if not args.dataset.exists():
        print(f"[error] dataset file not found: {args.dataset}", file=sys.stderr)
        sys.exit(1)

    test_ids = set(args.test_ids)

    lines = [l.strip() for l in args.dataset.read_text(encoding="utf-8").splitlines() if l.strip()]
    train_records: list[str] = []
    test_records: list[str] = []
    seen_ids: set[str] = set()

    for line in lines:
        cid = json.loads(line)["constitution_id"]
        seen_ids.add(cid)
        if cid in test_ids:
            test_records.append(line)
        else:
            train_records.append(line)

    missing = test_ids - seen_ids
    if missing:
        print(f"[warn] no records for test ids: {sorted(missing)}", file=sys.stderr)

    for path, records in ((args.train_output, train_records), (args.test_output, test_records)):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(line + "\n" for line in records), encoding="utf-8")

    print(f"Total {len(lines)} records from {args.dataset}")
    print(f"  train: {len(train_records)} -> {args.train_output}")
    print(f"  test:  {len(test_records)} (ids {sorted(test_ids)}) -> {args.test_output}")


if __name__ == "__main__":
    main()
