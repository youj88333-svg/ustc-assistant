import copy
import json
import tempfile
import unittest
from pathlib import Path

from jsonschema import Draft7Validator, Draft202012Validator, FormatChecker

from ustc_assistant.contracts.schema_export import (
    UnsupportedSchemaKeywordError,
    build_draft7_compat_schema,
    main,
)


REPO_ROOT = Path(__file__).parents[2]
CANONICAL_SCHEMA_PATH = (
    REPO_ROOT / "schemas" / "source-bundle-1.0.schema.json"
)
POSITIVE_FIXTURE_DIR = (
    REPO_ROOT / "tests" / "fixtures" / "source-bundle" / "positive"
)
NEGATIVE_FIXTURE_DIR = (
    REPO_ROOT / "tests" / "fixtures" / "source-bundle" / "negative"
)
FLUTTER_SCHEMA_ASSET = (
    REPO_ROOT
    / "app"
    / "assets"
    / "schemas"
    / "source-bundle-1.0.draft7.schema.json"
)


def load_canonical_schema() -> dict:
    return json.loads(CANONICAL_SCHEMA_PATH.read_text(encoding="utf-8"))


class Draft7SchemaExportTests(unittest.TestCase):
    def test_committed_flutter_asset_matches_generated_schema(self):
        expected = build_draft7_compat_schema(load_canonical_schema())
        committed = json.loads(
            FLUTTER_SCHEMA_ASSET.read_text(encoding="utf-8")
        )

        self.assertEqual(expected, committed)

    def test_conversion_rewrites_draft_specific_constructs_without_mutation(self):
        canonical = load_canonical_schema()
        original = copy.deepcopy(canonical)
        converted = build_draft7_compat_schema(canonical)

        self.assertEqual(canonical, original)
        self.assertEqual(
            converted["$schema"],
            "http://json-schema.org/draft-07/schema#",
        )
        self.assertIn("definitions", converted)
        self.assertNotIn("$defs", converted)
        encoded = json.dumps(converted)
        self.assertNotIn("#/$defs/", encoded)
        self.assertNotIn("minContains", encoded)
        self.assertNotIn("maxContains", encoded)
        Draft7Validator.check_schema(converted)

    def test_positive_corpus_has_equivalent_acceptance(self):
        canonical = load_canonical_schema()
        converted = build_draft7_compat_schema(canonical)
        validators = (
            Draft202012Validator(canonical, format_checker=FormatChecker()),
            Draft7Validator(converted, format_checker=FormatChecker()),
        )
        paths = sorted(POSITIVE_FIXTURE_DIR.glob("*.json"))
        self.assertEqual(len(paths), 4)
        for path in paths:
            instance = json.loads(path.read_text(encoding="utf-8"))
            outcomes = [validator.is_valid(instance) for validator in validators]
            self.assertEqual(outcomes, [True, True], path.name)

    def test_negative_corpus_has_equivalent_schema_acceptance(self):
        canonical = load_canonical_schema()
        converted = build_draft7_compat_schema(canonical)
        validators = (
            Draft202012Validator(canonical, format_checker=FormatChecker()),
            Draft7Validator(converted, format_checker=FormatChecker()),
        )
        paths = sorted(NEGATIVE_FIXTURE_DIR.glob("*.json"))
        self.assertEqual(len(paths), 3)
        for path in paths:
            instance = json.loads(path.read_text(encoding="utf-8"))
            outcomes = [validator.is_valid(instance) for validator in validators]
            self.assertEqual(outcomes[0], outcomes[1], path.name)

    def test_jw_component_mutations_have_equivalent_acceptance(self):
        canonical = load_canonical_schema()
        converted = build_draft7_compat_schema(canonical)
        validators = (
            Draft202012Validator(canonical, format_checker=FormatChecker()),
            Draft7Validator(converted, format_checker=FormatChecker()),
        )
        base = json.loads(
            (POSITIVE_FIXTURE_DIR / "jw-empty-exam.json").read_text(
                encoding="utf-8"
            )
        )
        cases = []

        swapped = copy.deepcopy(base)
        swapped["snapshot"]["scope"]["components"].reverse()
        cases.append(("swapped", swapped, True))

        duplicate = copy.deepcopy(base)
        duplicate["snapshot"]["scope"]["components"][1]["name"] = "course_table"
        cases.append(("duplicate", duplicate, False))

        missing = copy.deepcopy(base)
        missing["snapshot"]["scope"]["components"].pop()
        cases.append(("missing", missing, False))

        extra = copy.deepcopy(base)
        extra["snapshot"]["scope"]["components"].append(
            copy.deepcopy(extra["snapshot"]["scope"]["components"][0])
        )
        cases.append(("extra", extra, False))

        for name, instance, expected in cases:
            with self.subTest(name=name):
                outcomes = [
                    validator.is_valid(instance) for validator in validators
                ]
                self.assertEqual(outcomes, [expected, expected])

    def test_unsupported_future_keyword_is_rejected(self):
        canonical = load_canonical_schema()
        canonical["unevaluatedProperties"] = False
        with self.assertRaises(UnsupportedSchemaKeywordError):
            build_draft7_compat_schema(canonical)

    def test_unexpected_canonical_metaschema_is_rejected(self):
        canonical = load_canonical_schema()
        canonical["$schema"] = "https://example.invalid/future-schema"
        with self.assertRaises(UnsupportedSchemaKeywordError):
            build_draft7_compat_schema(canonical)

    def test_contains_bounds_are_rejected_outside_fixed_jw_components(self):
        canonical = load_canonical_schema()
        canonical["$defs"]["data"]["properties"]["sourceRecords"][
            "minContains"
        ] = 1
        with self.assertRaises(UnsupportedSchemaKeywordError):
            build_draft7_compat_schema(canonical)

    def test_jw_contains_without_required_name_is_not_safely_convertible(self):
        canonical = load_canonical_schema()
        constraint = canonical["$defs"]["jwScope"]["properties"][
            "components"
        ]["allOf"][0]["contains"]
        constraint.pop("required")
        with self.assertRaises(UnsupportedSchemaKeywordError):
            build_draft7_compat_schema(canonical)

    def test_cli_writes_only_requested_utf8_file_with_trailing_newline(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "source_bundle_draft7.schema.json"
            result = main(["--output", str(output)])
            self.assertEqual(result, 0)
            raw = output.read_bytes()
            self.assertTrue(raw.endswith(b"\n"))
            exported = json.loads(raw.decode("utf-8"))
            self.assertEqual(
                exported,
                build_draft7_compat_schema(load_canonical_schema()),
            )
            self.assertEqual(
                sorted(path.name for path in Path(directory).iterdir()),
                [output.name],
            )

    def test_cli_refuses_a_directory_as_the_output_file(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                main(["--output", directory])


if __name__ == "__main__":
    unittest.main()
