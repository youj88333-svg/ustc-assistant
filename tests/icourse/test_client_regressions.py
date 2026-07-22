from __future__ import annotations

import json
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

from ustc_assistant.sources.icourse import client as client_module

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "tests" / "fixtures" / "icourse"
NOW = datetime(2026, 7, 22, 12, 0, tzinfo=timezone.utc)
URL = "https://icourse.club/course/100/"


class FakeResponse:
    def __init__(self, status_code=200, text="", payload=None, headers=None):
        self.status_code = status_code
        self.text = text
        self._payload = payload
        self.headers = headers or {}

    def json(self):
        return self._payload


class FakeSession:
    def __init__(self, tokens, searches):
        self.tokens = list(tokens)
        self.searches = list(searches)
        self.token_requests = 0
        self.search_requests = []

    def post(self, url, **kwargs):
        self.token_requests += 1
        return self.tokens.pop(0)

    def get(self, url, **kwargs):
        self.search_requests.append(kwargs.get("params"))
        return self.searches.pop(0)


class ModuleContractTests(unittest.TestCase):
    def test_client_module_exists(self):
        self.assertIsNotNone(client_module, "public iCourse client module must exist")


@unittest.skipIf(client_module is None, "client module not implemented yet")
class HttpClientTests(unittest.TestCase):
    def test_search_retries_once_with_new_one_time_token(self):
        session = FakeSession(
            tokens=[FakeResponse(payload={"ok": True, "token": "old"}), FakeResponse(payload={"ok": True, "token": "new"})],
            searches=[FakeResponse(status_code=403), FakeResponse(text=(FIXTURES / "search.html").read_text(encoding="utf-8"))],
        )
        client = client_module.PublicIcourseClient(session=session, sleep=lambda _: None)

        result = client.search("Sample")

        self.assertEqual(2, session.token_requests)
        self.assertEqual("old", session.search_requests[0]["token"])
        self.assertEqual("new", session.search_requests[1]["token"])
        self.assertEqual("course", result[0]["kind"])

    def test_rate_limit_exposes_retry_after_without_sleep_loop(self):
        session = FakeSession(
            tokens=[FakeResponse(payload={"ok": True, "token": "one"})],
            searches=[FakeResponse(status_code=429, headers={"Retry-After": "17"})],
        )
        client = client_module.PublicIcourseClient(session=session, sleep=lambda _: None)

        with self.assertRaisesRegex(client_module.IcourseRateLimitError, "17"):
            client.search("Sample")


@unittest.skipIf(client_module is None, "client module not implemented yet")
class CacheTests(unittest.TestCase):
    def make_cache(self, root):
        return client_module.JsonPageCache(Path(root), ttl=timedelta(hours=24))

    def test_cache_is_fresh_before_but_not_at_exactly_24_hours(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            cache = self.make_cache(temporary_directory)
            cache.store(URL, {"name": "cached"}, fetched_at=NOW - timedelta(hours=24))
            calls = []

            result = cache.get_or_fetch(URL, lambda _: calls.append(True) or "new", lambda html, _: {"name": html}, now=NOW)

        self.assertEqual([True], calls)
        self.assertEqual("new", result.data["name"])
        self.assertFalse(result.stale)

    def test_network_failure_returns_expired_cache_as_stale(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            cache = self.make_cache(temporary_directory)
            cache.store(URL, {"name": "cached"}, fetched_at=NOW - timedelta(hours=25))

            def fail(_):
                raise client_module.IcourseNetworkError("offline")

            result = cache.get_or_fetch(URL, fail, lambda html, _: html, now=NOW)

        self.assertTrue(result.stale)
        self.assertEqual("cached", result.data["name"])

    def test_parse_failure_does_not_replace_valid_old_cache(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            cache = self.make_cache(temporary_directory)
            cache.store(URL, {"name": "old"}, fetched_at=NOW - timedelta(hours=25))

            with self.assertRaises(ValueError):
                cache.get_or_fetch(URL, lambda _: "broken", lambda *_: (_ for _ in ()).throw(ValueError("drift")), now=NOW)
            cached = cache.load(URL)

        self.assertEqual("old", cached.data["name"])
        self.assertEqual(NOW - timedelta(hours=25), cached.fetched_at)

    def test_incompatible_schema_is_ignored(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            cache = self.make_cache(temporary_directory)
            cache.store(URL, {"name": "old"}, fetched_at=NOW)
            path = next(Path(temporary_directory).glob("*.json"))
            payload = json.loads(path.read_text(encoding="utf-8"))
            payload["schemaVersion"] = "0.1"
            path.write_text(json.dumps(payload), encoding="utf-8")

            self.assertIsNone(cache.load(URL))


if __name__ == "__main__":
    unittest.main()
