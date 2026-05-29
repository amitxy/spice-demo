import json
from dataclasses import asdict, dataclass
from pathlib import Path


@dataclass
class DatasetSample:
    constitution_id: str
    query: str
    response: str


# def format_samples(
#     constitution_id: str,
#     queries: list[str],
#     responses: list[str],
# ) -> list[DatasetSample]:
#     if len(queries) != len(responses):
#         raise ValueError(f"queries and responses length mismatch: {len(queries)} vs {len(responses)}")
#     return [
#         DatasetSample(
#             constitution_id=constitution_id,
#             query=q,
#             response=r,
#         )
#         for q, r in zip(queries, responses)
#     ]


def write_jsonl(samples: list[DatasetSample], output_path: Path, append: bool = False) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    mode = "a" if append else "w"
    with output_path.open(mode, encoding="utf-8") as f:
        for sample in samples:
            f.write(json.dumps(asdict(sample), ensure_ascii=False) + "\n")
