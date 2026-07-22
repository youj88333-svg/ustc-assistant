import json
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import icourse_public_query as legacy_service

from ustc_assistant.sources.icourse import client, parser, service


class PublicServiceParityTests(unittest.TestCase):
    def test_jw_grouping_matches_legacy_and_excludes_bundle_metadata(self):
        bundle = json.loads(
            (ROOT / "examples" / "ustc-jw-import-bundle.sample.json").read_text(
                encoding="utf-8"
            )
        )

        actual = service.group_jw_offerings(bundle)

        self.assertEqual(actual, legacy_service.group_jw_offerings(bundle))
        serialized = json.dumps(actual, ensure_ascii=False)
        self.assertNotIn("sourceRecords", serialized)
        self.assertNotIn('"userId"', serialized)

    def test_public_modules_expose_parser_and_client(self):
        self.assertTrue(callable(parser.parse_course_page))
        self.assertTrue(hasattr(client, "PublicIcourseClient"))


if __name__ == "__main__":
    unittest.main()
