import json
import unittest
from pathlib import Path

from ustc_assistant.bridge.query_contracts import validate_query_result
from ustc_assistant.sources.young import enrolment


ACTIVITY = {
    "id": "activity-1",
    "itemName": "sample",
    "module_dictText": "Knowledge",
    "applyEt": "2026-07-31 23:59:00",
    "baseContent": "<p>Description</p>",
    "userId": "private-user",
    "unknownSensitiveField": "must-not-enter-normal-output",
}


BEIJING_TIME = "2026-07-22T08:00:00+08:00"
FIXTURE_PATH = Path(__file__).parents[1] / "fixtures/query-results/young-enrolment.json"
SAMPLE_COLLECTION = enrolment.CollectedEnrolmentActivities(
    records=(
        {
            "id": "activity-query-result-1",
            "itemName": "蹇楁効娲诲姩",
            "itemCategory": "service",
            "itemStatus": "open",
            "itemLimitNum": 24,
            "applyNum": 6,
        },
    ),
    reported_total=1,
    pages=1,
)


class EnrolmentServiceTests(unittest.TestCase):
    def test_young_query_result_matches_canonical_fixture(self):
        snapshot = enrolment.normalize_enrolments(
            SAMPLE_COLLECTION,
            collected_at=BEIJING_TIME,
        )

        actual = enrolment.build_young_query_result(snapshot)
        expected = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))

        self.assertEqual(expected, actual)

    def test_real_young_snapshot_is_wrapped_as_query_result(self):
        snapshot = enrolment.normalize_enrolments(
            SAMPLE_COLLECTION,
            collected_at=BEIJING_TIME,
        )

        envelope = enrolment.build_young_query_result(snapshot)

        validate_query_result(envelope)
        self.assertEqual("蹇楁効娲诲姩", envelope["data"]["activities"][0]["name"])

    def test_snapshot_collects_then_normalizes_without_user_identity(self):
        raw = enrolment.CollectedEnrolmentActivities(
            records=(ACTIVITY,), reported_total=1, pages=1
        )

        normalized, returned = enrolment.collect_enrolment_snapshot(
            collect_fn=lambda **kwargs: raw,
            collected_at="2026-07-22T08:00:00+08:00",
        )

        self.assertIs(returned, raw)
        self.assertEqual(normalized["metadata"]["activityCount"], 1)
        self.assertEqual(normalized["activities"][0]["name"], "sample")
        self.assertEqual(normalized["activities"][0]["moduleLabel"], "Knowledge")
        self.assertEqual(
            normalized["activities"][0]["applicationEndsAt"],
            "2026-07-31 23:59:00",
        )
        self.assertEqual(
            normalized["activities"][0]["descriptionText"], "Description"
        )
        self.assertNotIn("descriptionHtml", normalized["activities"][0])
        self.assertNotIn("userId", normalized["activities"][0])
        self.assertNotIn("unknownSensitiveField", normalized["activities"][0])


if __name__ == "__main__":
    unittest.main()
