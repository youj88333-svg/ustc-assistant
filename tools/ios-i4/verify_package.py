"""I4 adapter for the shared bounded unsigned-IPA auditor."""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path
from typing import Any


def _load_i1_auditor() -> Any:
    path = Path(__file__).resolve().parents[1] / "ios-i1" / "verify_package.py"
    spec = importlib.util.spec_from_file_location("ios_i1_shared_package_auditor", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("shared_auditor_unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_I1 = _load_i1_auditor()
VerificationError = _I1.VerificationError


def verify_package(
    ipa_path: str | Path,
    expected_revision: str,
    report_path: str | Path | None = None,
) -> dict[str, Any]:
    return _I1.verify_package(ipa_path, expected_revision, report_path, stage=4)


class _SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        del message
        _I1._fail("invalid_arguments")


def main(argv: list[str] | None = None) -> int:
    parser = _SafeArgumentParser(description="Verify an I4 unsigned iOS IPA.")
    parser.add_argument("--ipa", required=True)
    parser.add_argument("--expected-revision", required=True)
    parser.add_argument("--report", required=True)
    try:
        args = parser.parse_args(argv)
        report = verify_package(args.ipa, args.expected_revision, args.report)
    except VerificationError as exc:
        sys.stderr.write(f"verification failed: {exc.code}\n")
        return 2
    except SystemExit as exc:
        return int(exc.code or 0)
    except Exception:
        sys.stderr.write("verification failed: internal_error\n")
        return 2
    sys.stdout.write(
        json.dumps(report, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
        + "\n"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
