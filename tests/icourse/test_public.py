import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "tests" / "fixtures" / "jw" / "import-bundle.json"

from ustc_assistant.sources.icourse import client, parser, service


class PublicServiceContractTests(unittest.TestCase):
    def test_jw_grouping_excludes_bundle_metadata(self):
        bundle = json.loads(FIXTURE.read_text(encoding="utf-8"))

        offerings = service.group_jw_offerings(bundle)

        self.assertEqual(6, len(offerings))
        serialized = json.dumps(offerings, ensure_ascii=False)
        self.assertNotIn("sourceRecords", serialized)
        self.assertNotIn('"userId"', serialized)

    def test_public_modules_expose_parser_and_client(self):
        self.assertTrue(callable(parser.parse_course_page))
        self.assertTrue(hasattr(client, "PublicIcourseClient"))


if __name__ == "__main__":
    unittest.main()
