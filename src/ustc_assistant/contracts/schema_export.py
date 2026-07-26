import argparse
import copy
import json
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any


CANONICAL_SCHEMA_PATH = (
    Path(__file__).resolve().parents[3]
    / "schemas"
    / "source-bundle-1.0.schema.json"
)

_SCHEMA_KEYWORDS = {
    "$defs",
    "$id",
    "$ref",
    "$schema",
    "additionalProperties",
    "allOf",
    "const",
    "contains",
    "description",
    "else",
    "enum",
    "format",
    "if",
    "items",
    "maxContains",
    "maxItems",
    "maxLength",
    "maximum",
    "minContains",
    "minItems",
    "minLength",
    "minimum",
    "not",
    "oneOf",
    "pattern",
    "properties",
    "required",
    "then",
    "title",
    "type",
}
_SCHEMA_MAP_KEYWORDS = {"$defs", "properties"}
_SCHEMA_LIST_KEYWORDS = {"allOf", "oneOf"}
_SCHEMA_SINGLE_KEYWORDS = {
    "additionalProperties",
    "contains",
    "else",
    "if",
    "items",
    "not",
    "then",
}
_REMOVABLE_CONTAINS_BOUND_PATHS = {
    ("$defs", "jwScope", "properties", "components", "allOf", 0),
    ("$defs", "jwScope", "properties", "components", "allOf", 1),
}


class UnsupportedSchemaKeywordError(ValueError):
    pass


def build_draft7_compat_schema(
    canonical: Mapping[str, Any],
) -> dict[str, Any]:
    source = copy.deepcopy(dict(canonical))
    if source.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
        raise UnsupportedSchemaKeywordError(
            "Canonical schema metaschema is not supported"
        )
    _verify_redundant_jw_contains_bounds(source)
    converted = _rewrite_schema(source, ())
    converted["$schema"] = "http://json-schema.org/draft-07/schema#"
    return converted


def _verify_redundant_jw_contains_bounds(schema: Mapping[str, Any]) -> None:
    try:
        components = schema["$defs"]["jwScope"]["properties"]["components"]
        constraints = components["allOf"]
        names = {
            constraint["contains"]["properties"]["name"]["const"]
            for constraint in constraints
        }
        bounds_are_fixed = (
            components["minItems"] == 2
            and components["maxItems"] == 2
            and len(constraints) == 2
            and names == {"course_table", "exam_arrange"}
            and all(
                constraint.get("minContains") == 1
                and constraint.get("maxContains") == 1
                for constraint in constraints
            )
        )
    except (KeyError, TypeError):
        bounds_are_fixed = False
    if not bounds_are_fixed:
        raise UnsupportedSchemaKeywordError(
            "JW component contains bounds are not safely convertible"
        )


def _rewrite_schema(schema: Mapping[str, Any], path: tuple[Any, ...]) -> dict:
    unknown = set(schema) - _SCHEMA_KEYWORDS
    if unknown:
        raise UnsupportedSchemaKeywordError(
            "Canonical schema uses unsupported compatibility keywords: "
            + ", ".join(sorted(unknown))
        )

    converted: dict[str, Any] = {}
    for keyword, value in schema.items():
        current_path = path + (keyword,)
        if keyword in {"minContains", "maxContains"}:
            if path not in _REMOVABLE_CONTAINS_BOUND_PATHS:
                raise UnsupportedSchemaKeywordError(
                    "Contains bounds are unsupported outside JW components"
                )
            continue
        output_keyword = "definitions" if keyword == "$defs" else keyword
        if keyword == "$ref":
            converted[output_keyword] = value.replace(
                "#/$defs/", "#/definitions/"
            )
        elif keyword in _SCHEMA_MAP_KEYWORDS:
            converted[output_keyword] = {
                name: _rewrite_schema(child, current_path + (name,))
                for name, child in value.items()
            }
        elif keyword in _SCHEMA_LIST_KEYWORDS:
            converted[output_keyword] = [
                _rewrite_schema(child, current_path + (index,))
                for index, child in enumerate(value)
            ]
        elif (
            keyword in _SCHEMA_SINGLE_KEYWORDS
            and isinstance(value, Mapping)
        ):
            converted[output_keyword] = _rewrite_schema(value, current_path)
        else:
            converted[output_keyword] = copy.deepcopy(value)
    return converted


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Export the SourceBundle schema as Draft 7."
    )
    parser.add_argument("--output", required=True)
    args = parser.parse_args(argv)

    output = Path(args.output).resolve()
    if output.exists() and output.is_dir():
        raise ValueError("The output path must name a file")
    if not output.parent.is_dir():
        raise ValueError("The output parent directory must already exist")

    canonical = json.loads(
        CANONICAL_SCHEMA_PATH.read_text(encoding="utf-8")
    )
    converted = build_draft7_compat_schema(canonical)
    output.write_text(
        json.dumps(converted, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
