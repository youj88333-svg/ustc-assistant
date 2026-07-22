from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

from playwright.sync_api import Error as PlaywrightError
from ustc_assistant.sources.jw import collector

ROOT = Path(__file__).resolve().parents[2]


class FakeResponse:
    def __init__(self, status: int, payload, status_text: str = ""):
        self.status = status
        self._payload = payload
        self.status_text = status_text

    def json(self):
        return self._payload


class FakeRequestContext:
    def __init__(self, get_response: FakeResponse, post_response: FakeResponse):
        self.get_response = get_response
        self.post_response = post_response
        self.calls = []

    def get(self, url, **kwargs):
        self.calls.append(("GET", url, kwargs))
        return self.get_response

    def post(self, url, **kwargs):
        self.calls.append(("POST", url, kwargs))
        return self.post_response


class FakeNetworkResponse:
    def __init__(self, url: str):
        self.url = url


class FakeExpectedResponse:
    def __init__(self, response: FakeNetworkResponse):
        self.value = response

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False


class FakePage:
    def __init__(self, get_data_url: str, exam_html: str):
        self.url = "about:blank"
        self.get_data_response = FakeNetworkResponse(get_data_url)
        self.exam_html = exam_html
        self.goto_calls = []
        self.waited_selectors = []

    def goto(self, url, **kwargs):
        self.goto_calls.append((url, kwargs))
        if url == "https://jw.ustc.edu.cn/":
            self.url = "https://jw.ustc.edu.cn/home"
        elif url.endswith("/course-table"):
            self.url = "https://jw.ustc.edu.cn/for-std/course-table/info/redacted"
        elif url.endswith("/exam-arrange"):
            self.url = "https://jw.ustc.edu.cn/for-std/exam-arrange/info/redacted"

    def expect_response(self, predicate, **kwargs):
        if not predicate(self.get_data_response):
            raise AssertionError("response predicate rejected the fake get-data response")
        return FakeExpectedResponse(self.get_data_response)

    def wait_for_selector(self, selector, **kwargs):
        self.waited_selectors.append((selector, kwargs))

    def content(self):
        return self.exam_html


class FakeLoginPage:
    def __init__(self):
        self.url = "about:blank"
        self.goto_calls = []
        self.wait_patterns = []

    def goto(self, url, **kwargs):
        self.goto_calls.append(url)
        if url == "https://jw.ustc.edu.cn/":
            self.url = "https://jw.ustc.edu.cn/login"
        elif url == "https://jw.ustc.edu.cn/ucas-sso/login":
            self.url = "https://id.ustc.edu.cn/cas/login?service=redacted"

    def wait_for_url(self, pattern, **kwargs):
        self.wait_patterns.append((pattern, kwargs))
        self.url = "https://jw.ustc.edu.cn/home"


class FakeBrowserContext:
    def __init__(self, page: FakePage, request: FakeRequestContext):
        self.pages = [page]
        self.request = request
        page.context = self
        self.closed = False

    def close(self):
        self.closed = True


class FakeChromium:
    def __init__(self, context: FakeBrowserContext):
        self.context = context
        self.launch_calls = []

    def launch_persistent_context(self, user_data_dir, **kwargs):
        self.launch_calls.append((user_data_dir, kwargs))
        return self.context


class FakePlaywrightManager:
    def __init__(self, chromium: FakeChromium):
        self.chromium = chromium

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False


class ModuleContractTests(unittest.TestCase):
    def test_collector_module_exists(self):
        self.assertIsNotNone(collector, "browser collector module must exist")


@unittest.skipIf(collector is None, "browser collector module not implemented yet")
class CourseUrlTests(unittest.TestCase):
    def test_extracts_data_id_from_exact_get_data_url(self):
        url = (
            "https://jw.ustc.edu.cn/for-std/course-table/get-data"
            "?bizTypeId=2&semesterId=441&dataId=context-secret"
        )

        self.assertEqual("context-secret", collector.extract_data_id(url))

    def test_rejects_missing_data_id_without_leaking_url(self):
        url = (
            "https://jw.ustc.edu.cn/for-std/course-table/get-data"
            "?bizTypeId=2&semesterId=441"
        )

        with self.assertRaises(collector.CollectionError) as caught:
            collector.extract_data_id(url)

        self.assertNotIn(url, str(caught.exception))

    def test_rejects_other_endpoint_without_leaking_data_id(self):
        url = (
            "https://jw.ustc.edu.cn/for-std/course-table/other"
            "?dataId=context-secret"
        )

        with self.assertRaises(collector.CollectionError) as caught:
            collector.extract_data_id(url)

        self.assertNotIn("context-secret", str(caught.exception))

    def test_builds_get_data_url_for_configured_semester(self):
        url = collector.build_get_data_url(421, "context-secret")
        parsed = urlsplit(url)
        query = parse_qs(parsed.query)

        self.assertEqual("https", parsed.scheme)
        self.assertEqual("jw.ustc.edu.cn", parsed.netloc)
        self.assertEqual(
            "/for-std/course-table/get-data",
            parsed.path,
        )
        self.assertEqual(["2"], query["bizTypeId"])
        self.assertEqual(["421"], query["semesterId"])
        self.assertEqual(["context-secret"], query["dataId"])


@unittest.skipIf(collector is None, "browser collector module not implemented yet")
class CourseRequestTests(unittest.TestCase):
    def test_fetches_configured_semester_and_posts_lesson_ids(self):
        datum = {
            "result": {
                "lessonList": [],
                "scheduleList": [],
                "scheduleGroupList": [],
            }
        }
        request = FakeRequestContext(
            FakeResponse(200, {"lessonIds": [101, 202]}),
            FakeResponse(200, datum),
        )

        result = collector.fetch_course_datum(
            request,
            semester_id=421,
            data_id="context-secret",
            referer="https://jw.ustc.edu.cn/for-std/course-table/info/redacted",
        )

        self.assertEqual(datum, result)
        self.assertEqual(2, len(request.calls))
        method, get_url, get_kwargs = request.calls[0]
        self.assertEqual("GET", method)
        self.assertEqual(["421"], parse_qs(urlsplit(get_url).query)["semesterId"])
        self.assertEqual(
            ["context-secret"],
            parse_qs(urlsplit(get_url).query)["dataId"],
        )
        self.assertEqual(
            "XMLHttpRequest",
            get_kwargs["headers"]["X-Requested-With"],
        )
        method, post_url, post_kwargs = request.calls[1]
        self.assertEqual("POST", method)
        self.assertEqual(
            "https://jw.ustc.edu.cn/for-std/course-table/datum",
            post_url,
        )
        self.assertEqual({"lessonIds": [101, 202]}, post_kwargs["data"])

    def test_rejects_get_data_http_error_without_leaking_context(self):
        request = FakeRequestContext(
            FakeResponse(403, {"secret": "response-body"}, "Forbidden"),
            FakeResponse(200, {}),
        )

        with self.assertRaises(collector.CollectionError) as caught:
            collector.fetch_course_datum(
                request,
                semester_id=421,
                data_id="context-secret",
                referer="https://jw.ustc.edu.cn/for-std/course-table/info/redacted",
            )

        message = str(caught.exception)
        self.assertIn("get-data", message)
        self.assertIn("403", message)
        self.assertNotIn("context-secret", message)
        self.assertNotIn("response-body", message)

    def test_rejects_empty_lesson_ids_for_test_semester(self):
        request = FakeRequestContext(
            FakeResponse(200, {"lessonIds": []}),
            FakeResponse(200, {}),
        )

        with self.assertRaisesRegex(
            collector.CollectionError,
            r"no lessons.*421",
        ):
            collector.fetch_course_datum(
                request,
                semester_id=421,
                data_id="context-secret",
                referer="https://jw.ustc.edu.cn/for-std/course-table/info/redacted",
            )

        self.assertEqual(1, len(request.calls))

    def test_rejects_datum_http_error_without_leaking_response(self):
        request = FakeRequestContext(
            FakeResponse(200, {"lessonIds": [101]}),
            FakeResponse(500, {"secret": "response-body"}, "Server Error"),
        )

        with self.assertRaises(collector.CollectionError) as caught:
            collector.fetch_course_datum(
                request,
                semester_id=421,
                data_id="context-secret",
                referer="https://jw.ustc.edu.cn/for-std/course-table/info/redacted",
            )

        message = str(caught.exception)
        self.assertIn("datum", message)
        self.assertIn("500", message)
        self.assertNotIn("response-body", message)


@unittest.skipIf(collector is None, "browser collector module not implemented yet")
class BrowserBoundaryTests(unittest.TestCase):
    def test_default_profile_uses_windows_local_app_data(self):
        local_app_data = Path("C:/Users/Sample/AppData/Local")
        with patch.dict(os.environ, {"LOCALAPPDATA": str(local_app_data)}):
            profile = collector.default_profile_dir()

        self.assertEqual(
            local_app_data / "USTC Campus Assistant" / "edge-profile",
            profile,
        )
        self.assertFalse(profile.is_relative_to(ROOT))

    def test_get_data_response_predicate_accepts_only_exact_endpoint(self):
        self.assertTrue(
            collector.is_get_data_url(
                "https://jw.ustc.edu.cn/for-std/course-table/get-data"
                "?semesterId=441&dataId=context-secret"
            )
        )
        self.assertFalse(
            collector.is_get_data_url(
                "https://jw.ustc.edu.cn/for-std/course-table/datum"
            )
        )
        self.assertFalse(
            collector.is_get_data_url(
                "https://example.edu/for-std/course-table/get-data"
                "?dataId=context-secret"
            )
        )

    def test_collected_sources_has_in_memory_course_and_exam_fields(self):
        sources = collector.CollectedSources(
            course_datum={"result": {}},
            exam_html='<table id="exams"></table>',
        )

        self.assertEqual({"result": {}}, sources.course_datum)
        self.assertIn('id="exams"', sources.exam_html)

    def test_collect_sources_uses_visible_persistent_edge_and_closes_context(self):
        datum = {
            "result": {
                "lessonList": [],
                "scheduleList": [],
                "scheduleGroupList": [],
            }
        }
        request = FakeRequestContext(
            FakeResponse(200, {"lessonIds": [101]}),
            FakeResponse(200, datum),
        )
        page = FakePage(
            "https://jw.ustc.edu.cn/for-std/course-table/get-data"
            "?semesterId=441&dataId=context-secret",
            '<html><table id="exams"></table></html>',
        )
        context = FakeBrowserContext(page, request)
        chromium = FakeChromium(context)
        manager = FakePlaywrightManager(chromium)

        with tempfile.TemporaryDirectory() as temporary_directory:
            profile_dir = Path(temporary_directory) / "profile"
            result = collector.collect_sources(
                semester_id=421,
                profile_dir=profile_dir,
                playwright_factory=lambda: manager,
                status=lambda message: None,
            )

        self.assertEqual(datum, result.course_datum)
        self.assertIn('id="exams"', result.exam_html)
        self.assertEqual(1, len(chromium.launch_calls))
        launched_profile, launch_options = chromium.launch_calls[0]
        self.assertEqual(str(profile_dir), launched_profile)
        self.assertEqual("msedge", launch_options["channel"])
        self.assertFalse(launch_options["headless"])
        self.assertEqual(
            [
                "https://jw.ustc.edu.cn/",
                "https://jw.ustc.edu.cn/for-std/course-table",
                "https://jw.ustc.edu.cn/for-std/exam-arrange",
            ],
            [url for url, _ in page.goto_calls],
        )
        self.assertEqual("table#exams", page.waited_selectors[0][0])
        self.assertTrue(context.closed)

    def test_missing_session_opens_stable_cas_entry_and_waits_for_home(self):
        page = FakeLoginPage()
        messages = []

        collector._ensure_authenticated(
            page,
            login_timeout_ms=1234,
            status=messages.append,
        )

        self.assertEqual(
            [
                "https://jw.ustc.edu.cn/",
                "https://jw.ustc.edu.cn/ucas-sso/login",
            ],
            page.goto_calls,
        )
        self.assertEqual(1234, page.wait_patterns[0][1]["timeout"])
        self.assertTrue(any("CAS" in message for message in messages))

    def test_playwright_error_is_sanitized(self):
        class FailingChromium:
            def launch_persistent_context(self, user_data_dir, **kwargs):
                raise PlaywrightError(
                    "navigation failed at ?dataId=context-secret"
                )

        manager = FakePlaywrightManager(FailingChromium())

        with tempfile.TemporaryDirectory() as temporary_directory:
            with self.assertRaises(collector.CollectionError) as caught:
                collector.collect_sources(
                    semester_id=421,
                    profile_dir=Path(temporary_directory) / "profile",
                    playwright_factory=lambda: manager,
                    status=lambda message: None,
                )

        message = str(caught.exception)
        self.assertIn("browser automation failed", message)
        self.assertNotIn("context-secret", message)


if __name__ == "__main__":
    unittest.main()
