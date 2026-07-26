import copy
import json
import unittest
from pathlib import Path

from ustc_assistant.contracts import (
    SourceBundleValidationError,
    canonical_bundle_digest,
    make_bundle_envelope,
    validate_source_bundle,
    validate_source_bundle_subject,
)


FIXTURE_ROOT = Path(__file__).parents[1] / "fixtures" / "source-bundle"
POSITIVE_FIXTURE_DIR = FIXTURE_ROOT / "positive"
NEGATIVE_FIXTURE_DIR = FIXTURE_ROOT / "negative"


def load_fixture(name: str) -> dict:
    return json.loads(
        (POSITIVE_FIXTURE_DIR / name).read_text(encoding="utf-8")
    )


class SourceBundleContractTests(unittest.TestCase):
    def test_all_four_shared_fixtures_validate(self):
        paths = sorted(POSITIVE_FIXTURE_DIR.glob("*.json"))
        self.assertEqual(len(paths), 4)
        for path in paths:
            validate_source_bundle(json.loads(path.read_text(encoding="utf-8")))

    def test_rejection_fixtures_have_stable_safe_categories(self):
        expected = {
            "count-mismatch.json": "count_mismatch",
            "incomplete-snapshot.json": "incomplete_snapshot",
            "unknown-field.json": "invalid_envelope",
        }
        self.assertEqual(
            {path.name for path in NEGATIVE_FIXTURE_DIR.glob("*.json")},
            set(expected),
        )
        for name, code in expected.items():
            bundle = json.loads(
                (NEGATIVE_FIXTURE_DIR / name).read_text(encoding="utf-8")
            )
            with self.assertRaises(SourceBundleValidationError) as caught:
                validate_source_bundle(bundle)
            self.assertEqual(caught.exception.code, code)
            self.assertNotIn("acct_fixture", str(caught.exception))

    def test_duplicate_external_identity_is_rejected_safely(self):
        bundle = load_fixture("jw-with-exam.json")
        bundle["data"]["calendarEvents"].append(
            copy.deepcopy(bundle["data"]["calendarEvents"][0])
        )
        with self.assertRaises(SourceBundleValidationError) as caught:
            validate_source_bundle(bundle)
        self.assertEqual(caught.exception.code, "duplicate_identity")
        self.assertNotIn(
            bundle["data"]["calendarEvents"][0]["externalId"],
            str(caught.exception),
        )

    def test_manifest_mismatch_is_rejected(self):
        bundle = load_fixture("young-with-schedule.json")
        bundle["manifest"]["calendarEventCount"] = 0
        self.assert_validation_code(bundle, "count_mismatch")

    def test_jw_component_counts_must_match_source_records(self):
        bundle = load_fixture("jw-with-exam.json")
        bundle["snapshot"]["scope"]["components"][0][
            "observedRecordCount"
        ] = 1
        self.assert_validation_code(bundle, "count_mismatch")

    def test_dangling_series_reference_is_rejected_safely(self):
        bundle = load_fixture("jw-with-exam.json")
        missing_identity = "ustc_jw:2026fall:series:lesson:missing-private"
        bundle["data"]["calendarEvents"][0][
            "seriesExternalId"
        ] = missing_identity
        with self.assertRaises(SourceBundleValidationError) as caught:
            validate_source_bundle(bundle)
        self.assertEqual(caught.exception.code, "dangling_reference")
        self.assertNotIn(missing_identity, str(caught.exception))

    def test_every_entity_requires_exactly_one_source_record(self):
        bundle = load_fixture("young-with-schedule.json")
        bundle["data"]["sourceRecords"] = []
        bundle["manifest"]["sourceRecordCount"] = 0
        self.assert_validation_code(bundle, "dangling_reference")

    def test_duplicate_source_record_mapping_is_rejected(self):
        bundle = load_fixture("young-with-schedule.json")
        duplicate_mapping = copy.deepcopy(bundle["data"]["sourceRecords"][0])
        duplicate_mapping["externalId"] = (
            "ustc_young_my_schedule:record:schedule:second-record"
        )
        bundle["data"]["sourceRecords"].append(duplicate_mapping)
        bundle["manifest"]["sourceRecordCount"] = 2
        self.assert_validation_code(bundle, "duplicate_identity")

    def test_source_record_type_must_match_its_target_entity(self):
        bundle = load_fixture("jw-with-exam.json")
        bundle["data"]["sourceRecords"][1]["entityExternalId"] = bundle[
            "data"
        ]["calendarEvents"][1]["externalId"]
        bundle["data"]["sourceRecords"][2]["entityExternalId"] = bundle[
            "data"
        ]["calendarEvents"][0]["externalId"]
        self.assert_validation_code(bundle, "dangling_reference")

    def test_exam_relation_primary_must_be_an_exam_event(self):
        bundle = load_fixture("jw-with-exam.json")
        relation_id = "ustc_jw:2026fall:relation:exam-for-course:private"
        bundle["data"]["scheduleRelations"].append(
            {
                "externalId": relation_id,
                "relationType": "exam_for_course",
                "primary": {
                    "entityType": "calendar_event",
                    "externalId": bundle["data"]["calendarEvents"][0][
                        "externalId"
                    ],
                },
                "related": {
                    "entityType": "course_series",
                    "externalId": bundle["data"]["courseSeries"][0][
                        "externalId"
                    ],
                },
            }
        )
        bundle["data"]["sourceRecords"].append(
            {
                "externalId": (
                    "ustc_jw:2026fall:record:exam-course-relation:private"
                ),
                "recordType": "jw_exam_course_relation",
                "entityType": "schedule_relation",
                "entityExternalId": relation_id,
                "sourceStatus": "active",
                "sourceUpdatedAt": None,
            }
        )
        bundle["manifest"]["sourceRecordCount"] = 4
        bundle["manifest"]["scheduleRelationCount"] = 1
        bundle["snapshot"]["scope"]["components"][1][
            "observedRecordCount"
        ] = 2

        with self.assertRaises(SourceBundleValidationError) as caught:
            validate_source_bundle(bundle)
        self.assertEqual(caught.exception.code, "dangling_reference")
        self.assertNotIn(relation_id, str(caught.exception))

    def test_non_beijing_offset_is_invalid_time(self):
        bundle = load_fixture("young-with-schedule.json")
        bundle["data"]["calendarEvents"][0]["time"][
            "startAt"
        ] = "2026-07-22T19:00:00+00:00"
        self.assert_validation_code(bundle, "invalid_time")

    def test_timed_event_must_end_after_it_starts(self):
        bundle = load_fixture("young-with-schedule.json")
        bundle["data"]["calendarEvents"][0]["time"][
            "endAt"
        ] = "2026-07-22T18:59:59+08:00"
        self.assert_validation_code(bundle, "invalid_time")

    def test_all_day_event_must_have_positive_date_range(self):
        bundle = load_fixture("young-with-schedule.json")
        bundle["data"]["calendarEvents"][0]["time"] = {
            "kind": "all_day",
            "startDate": "2026-07-22",
            "endDateExclusive": "2026-07-22",
            "timezone": "Asia/Shanghai",
        }
        self.assert_validation_code(bundle, "invalid_time")

    def test_incomplete_snapshot_is_rejected_with_specific_code(self):
        bundle = load_fixture("young-empty-window.json")
        bundle["snapshot"]["completeness"] = "partial"
        self.assert_validation_code(bundle, "incomplete_snapshot")

    def test_date_window_counts_and_order_are_checked(self):
        wrong_count = load_fixture("young-empty-window.json")
        wrong_count["snapshot"]["scope"]["expectedDateCount"] = 38
        self.assert_validation_code(wrong_count, "count_mismatch")

        reversed_window = load_fixture("young-empty-window.json")
        reversed_window["snapshot"]["scope"]["fromDate"] = "2026-08-26"
        self.assert_validation_code(reversed_window, "invalid_time")

    def test_event_outside_complete_date_window_is_rejected(self):
        bundle = load_fixture("young-with-schedule.json")
        bundle["data"]["calendarEvents"][0]["time"][
            "startAt"
        ] = "2026-09-01T19:00:00+08:00"
        bundle["data"]["calendarEvents"][0]["time"][
            "endAt"
        ] = "2026-09-01T20:30:00+08:00"
        self.assert_validation_code(bundle, "invalid_time")

    def test_hard_text_limit_is_reported_without_echoing_text(self):
        bundle = load_fixture("young-with-schedule.json")
        private_title = "私" * 501
        bundle["data"]["calendarEvents"][0]["title"] = private_title
        with self.assertRaises(SourceBundleValidationError) as caught:
            validate_source_bundle(bundle)
        self.assertEqual(caught.exception.code, "limit_exceeded")
        self.assertNotIn(private_title, str(caught.exception))

    def test_unknown_and_sensitive_fields_are_rejected_safely(self):
        bundle = load_fixture("young-empty-window.json")
        private_value = "do-not-echo-private-token"
        bundle["producer"]["token"] = private_value
        with self.assertRaises(SourceBundleValidationError) as caught:
            validate_source_bundle(bundle)
        self.assertEqual(caught.exception.code, "invalid_envelope")
        self.assertNotIn(private_value, str(caught.exception))

    def test_unknown_time_field_is_an_invalid_envelope(self):
        bundle = load_fixture("young-with-schedule.json")
        bundle["data"]["calendarEvents"][0]["time"]["unexpected"] = "private"
        self.assert_validation_code(bundle, "invalid_envelope")

    def test_higher_minor_and_major_versions_are_unsupported(self):
        for version in ("1.1", "2.0"):
            with self.subTest(version=version):
                bundle = load_fixture("young-empty-window.json")
                bundle["schemaVersion"] = version
                self.assert_validation_code(bundle, "unsupported_version")

    def test_subject_match_helper_rejects_without_echoing_identities(self):
        bundle = load_fixture("young-empty-window.json")
        expected = "acct_expected_private"
        with self.assertRaises(SourceBundleValidationError) as caught:
            validate_source_bundle_subject(bundle, expected)
        self.assertEqual(caught.exception.code, "subject_mismatch")
        self.assertNotIn(expected, str(caught.exception))
        self.assertNotIn(bundle["subject"]["accountId"], str(caught.exception))

    def test_subject_match_helper_accepts_matching_account(self):
        bundle = load_fixture("young-empty-window.json")
        validate_source_bundle_subject(bundle, "acct_fixture")

    def test_digest_is_canonical_utf8_sha256(self):
        first = {"b": "中", "a": 1}
        second = {"a": 1, "b": "中"}
        expected = (
            "2831299868169bc527f55f88ebbdcd8b"
            "785d78d9e7dc64e6887dfbd2825dd247"
        )
        self.assertEqual(canonical_bundle_digest(first), expected)
        self.assertEqual(canonical_bundle_digest(second), expected)

    def test_make_bundle_envelope_derives_manifest_and_copies_inputs(self):
        fixture = load_fixture("young-with-schedule.json")
        snapshot = fixture["snapshot"]
        data = fixture["data"]
        envelope = make_bundle_envelope(
            bundle_id=fixture["bundleId"],
            source=fixture["source"],
            account_id=fixture["subject"]["accountId"],
            collected_at=fixture["collectedAt"],
            snapshot=snapshot,
            data=data,
            producer=fixture["producer"],
        )
        self.assertEqual(envelope, fixture)
        self.assertIsNot(envelope["snapshot"], snapshot)
        self.assertIsNot(envelope["data"], data)

    def assert_validation_code(self, bundle: dict, code: str):
        with self.assertRaises(SourceBundleValidationError) as caught:
            validate_source_bundle(bundle)
        self.assertEqual(caught.exception.code, code)


if __name__ == "__main__":
    unittest.main()
