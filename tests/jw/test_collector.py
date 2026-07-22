import unittest

from ustc_assistant.sources.jw import collector


class CollectorContractTests(unittest.TestCase):
    def test_builds_configured_semester_url_without_exposing_context_elsewhere(self):
        url = collector.build_get_data_url(421, "private-context")

        self.assertIn("semesterId=421", url)
        self.assertIn("dataId=private-context", url)
        self.assertTrue(collector.is_get_data_url(url))


if __name__ == "__main__":
    unittest.main()
