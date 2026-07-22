"""Privacy-aware local output helpers."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


def dump_json(path: Path, payload: Any) -> Path:
    output = Path(path)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8", newline="\n") as file:
        json.dump(payload, file, ensure_ascii=False, indent=2)
        file.write("\n")
    return output


def write_raw_json(raw_dir: Path, filename: str, payload: Any) -> Path:
    return dump_json(Path(raw_dir) / filename, payload)


def write_raw_text(raw_dir: Path, filename: str, payload: str) -> Path:
    output = Path(raw_dir) / filename
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(payload, encoding="utf-8", newline="\n")
    return output
