import unittest

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


class EnrolmentServiceTests(unittest.TestCase):
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
