import unittest

from ustc_assistant import cli


class PackageEntryTests(unittest.TestCase):
    def test_root_parser_exposes_collect_and_query(self):
        parser = cli.build_parser()

        collect_args = parser.parse_args(["collect", "jw"])
        query_args = parser.parse_args(["query", "icourse", "--course", "test"])

        self.assertEqual(collect_args.command, "collect")
        self.assertEqual(collect_args.source, "jw")
        self.assertEqual(query_args.command, "query")
        self.assertEqual(query_args.source, "icourse")


if __name__ == "__main__":
    unittest.main()
