from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "ustc_young_collector.py"


def load_collector_module():
    if not MODULE_PATH.exists():
        return None
    spec = importlib.util.spec_from_file_location("ustc_young_collector", MODULE_PATH)
    if spec is None or spec.loader is None:
        return None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


collector = load_collector_module()


class FakeRequest:
    def __init__(self, method: str = "GET"):
        self.method = method


class FakeResponse:
    def __init__(self, payload, *, status: int = 200, method: str = "GET"):
        self.url = (
            "https://young.ustc.edu.cn/login/wisdom-group-learning-bg/"
            "mobile/item/enrolmentList?_t=redacted&requestParams=redacted"
        )
        self.status = status
        self.request = FakeRequest(method)
        self._payload = payload

    def json(self):
        return self._payload


def page_payload(records, *, total: int, pages: int, current: int = 1):
    return {
        "success": True,
        "message": "operation succeeded",
        "code": 200,
        "result": {
            "records": records,
            "total": total,
            "size": 10,
            "current": current,
            "orders": [],
            "pages": pages,
        },
    }


class FakeExpectedResponse:
    def __init__(self, response):
        self.value = response

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False


class FakeLocator:
    def __init__(self, *, visible: bool = True):
        self.clicks = 0
        self.wait_calls = []
        self.visible = visible

    def wait_for(self, **kwargs):
        self.wait_calls.append(kwargs)
        if not self.visible:
            raise collector.PlaywrightTimeoutError("locator was not visible")

    def is_visible(self):
        return self.visible

    def click(self):
        self.clicks += 1


class FakePage:
    def __init__(self, responses):
        self.url = "about:blank"
        self.responses = list(responses)
        self.goto_calls = []
        self.tab = FakeLocator()
        self.next_button = FakeLocator()

    def goto(self, url, **kwargs):
        self.goto_calls.append((url, kwargs))
        self.url = url

    def get_by_text(self, text, **kwargs):
        if text != "报名中" or not kwargs.get("exact"):
            raise AssertionError("unexpected text locator")
        return self.tab

    def locator(self, selector):
        if selector != "li.ant-pagination-next":
            raise AssertionError(f"unexpected selector: {selector}")
        return self.next_button

    def expect_response(self, predicate, **kwargs):
        if not self.responses:
            raise AssertionError("no fake response remains")
        response = self.responses.pop(0)
        if not predicate(response):
            raise AssertionError("response predicate rejected enrolmentList")
        return FakeExpectedResponse(response)

    def wait_for_timeout(self, timeout):
        return None


class FakeRedirectingLoginPage(FakePage):
    def __init__(self, responses):
        super().__init__(responses)
        self.tab = FakeLocator(visible=False)
        self.polls = 0

    def goto(self, url, **kwargs):
        self.goto_calls.append((url, kwargs))
        if len(self.goto_calls) == 1:
            self.url = "https://id.ustc.edu.cn/cas/login?service=redacted"
        else:
            self.url = url
            self.tab.visible = True

    def wait_for_timeout(self, timeout):
        self.polls += 1
        self.url = (
            "https://young.ustc.edu.cn/login/"
            "sc-wisdom-group-learning/dataAnalysis/visual"
        )


class FakeBrowserContext:
    def __init__(self, page):
        self.pages = [page]
        self.closed = False

    def close(self):
        self.closed = True


class FakeChromium:
    def __init__(self, context):
        self.context = context
        self.launch_calls = []

    def launch_persistent_context(self, user_data_dir, **kwargs):
        self.launch_calls.append((user_data_dir, kwargs))
        return self.context


class FakePlaywrightManager:
    def __init__(self, chromium):
        self.chromium = chromium

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False


class ModuleContractTests(unittest.TestCase):
    def test_collector_module_exists(self):
        self.assertIsNotNone(collector, "second-classroom collector must exist")


@unittest.skipIf(collector is None, "collector module not implemented yet")
class ResponseContractTests(unittest.TestCase):
    def test_matches_only_exact_enrolment_list_response(self):
        response = FakeResponse(page_payload([], total=0, pages=0))

        self.assertTrue(collector.is_enrolment_list_response(response))

        response.url = response.url.replace("young.ustc.edu.cn", "example.edu")
        self.assertFalse(collector.is_enrolment_list_response(response))
        response.url = (
            "https://young.ustc.edu.cn/login/wisdom-group-learning-bg/"
            "mobile/item/enrolmentList/other"
        )
        self.assertFalse(collector.is_enrolment_list_response(response))
        response.url = "http://young.ustc.edu.cn/login/wisdom-group-learning-bg/mobile/item/enrolmentList"
        self.assertFalse(collector.is_enrolment_list_response(response))

    def test_rejects_non_get_or_non_success_response(self):
        payload = page_payload([], total=0, pages=0)

        self.assertFalse(
            collector.is_enrolment_list_response(FakeResponse(payload, method="POST"))
        )
        self.assertFalse(
            collector.is_enrolment_list_response(FakeResponse(payload, status=403))
        )

    def test_parses_valid_page_without_trusting_current(self):
        response = FakeResponse(
            page_payload([{"id": "activity-2"}], total=11, pages=2, current=1)
        )

        result = collector.parse_enrolment_page(response)

        self.assertEqual(11, result.total)
        self.assertEqual(2, result.pages)
        self.assertEqual(({"id": "activity-2"},), result.records)

    def test_rejects_invalid_payload_without_exposing_body(self):
        response = FakeResponse({"success": False, "secret": "response-body"})

        with self.assertRaises(collector.CollectionError) as caught:
            collector.parse_enrolment_page(response)

        self.assertNotIn("response-body", str(caught.exception))


@unittest.skipIf(collector is None, "collector module not implemented yet")
class PaginationTests(unittest.TestCase):
    def test_collects_two_pages_and_ignores_current(self):
        page = FakePage(
            [
                FakeResponse(
                    page_payload(
                        [{"id": "a", "itemName": "A"}],
                        total=2,
                        pages=2,
                        current=1,
                    )
                ),
                FakeResponse(
                    page_payload(
                        [{"id": "b", "itemName": "B"}],
                        total=2,
                        pages=2,
                        current=1,
                    )
                ),
            ]
        )

        result = collector.collect_from_page(
            page,
            login_timeout_ms=1234,
            response_timeout_ms=5678,
        )

        self.assertEqual(("a", "b"), tuple(record["id"] for record in result.records))
        self.assertEqual(2, result.reported_total)
        self.assertEqual(2, result.pages)
        self.assertEqual(1, page.tab.clicks)
        self.assertEqual(1, page.next_button.clicks)

    def test_reopens_sign_up_after_login_lands_on_visual_dashboard(self):
        page = FakeRedirectingLoginPage(
            [FakeResponse(page_payload([{"id": "a"}], total=1, pages=1))]
        )

        result = collector.collect_from_page(
            page,
            login_timeout_ms=1234,
            response_timeout_ms=5678,
        )

        self.assertEqual("a", result.records[0]["id"])
        self.assertEqual(2, len(page.goto_calls))
        self.assertTrue(
            all(call[0] == collector.SIGN_UP_URL for call in page.goto_calls)
        )
        self.assertGreaterEqual(page.polls, 1)

    def test_deduplicates_identical_activity_records(self):
        duplicate = {"id": "same", "itemName": "Same"}
        page = FakePage(
            [
                FakeResponse(page_payload([duplicate], total=1, pages=2)),
                FakeResponse(page_payload([duplicate], total=1, pages=2)),
            ]
        )

        result = collector.collect_from_page(page)

        self.assertEqual((duplicate,), result.records)

    def test_rejects_conflicting_duplicate_activity(self):
        page = FakePage(
            [
                FakeResponse(
                    page_payload([{"id": "same", "itemName": "A"}], total=1, pages=2)
                ),
                FakeResponse(
                    page_payload([{"id": "same", "itemName": "B"}], total=1, pages=2)
                ),
            ]
        )

        with self.assertRaisesRegex(
            collector.CollectionError,
            "conflicting duplicate activity",
        ):
            collector.collect_from_page(page)

    def test_rejects_unique_count_mismatch(self):
        page = FakePage(
            [FakeResponse(page_payload([{"id": "only"}], total=2, pages=1))]
        )

        with self.assertRaisesRegex(collector.CollectionError, "expected 2.*collected 1"):
            collector.collect_from_page(page)


@unittest.skipIf(collector is None, "collector module not implemented yet")
class BrowserBoundaryTests(unittest.TestCase):
    def test_default_profile_matches_existing_ustc_profile(self):
        local_app_data = Path("C:/Users/Sample/AppData/Local")
        with patch.dict(os.environ, {"LOCALAPPDATA": str(local_app_data)}):
            profile = collector.default_profile_dir()

        self.assertEqual(
            local_app_data / "USTC Campus Assistant" / "edge-profile",
            profile,
        )

    def test_collect_activities_uses_visible_persistent_edge_and_closes_context(self):
        page = FakePage(
            [FakeResponse(page_payload([{"id": "a"}], total=1, pages=1))]
        )
        context = FakeBrowserContext(page)
        chromium = FakeChromium(context)
        manager = FakePlaywrightManager(chromium)

        with tempfile.TemporaryDirectory() as temporary_directory:
            profile = Path(temporary_directory) / "profile"
            result = collector.collect_activities(
                profile_dir=profile,
                playwright_factory=lambda: manager,
                status=lambda message: None,
            )

        self.assertEqual("a", result.records[0]["id"])
        launched_profile, options = chromium.launch_calls[0]
        self.assertEqual(str(profile), launched_profile)
        self.assertEqual("msedge", options["channel"])
        self.assertFalse(options["headless"])
        self.assertTrue(options["no_viewport"])
        self.assertTrue(context.closed)

    def test_playwright_error_is_sanitized(self):
        class FailingChromium:
            def launch_persistent_context(self, user_data_dir, **kwargs):
                raise collector.PlaywrightError(
                    "failed with X-Access-Token=secret&requestParams=secret"
                )

        manager = FakePlaywrightManager(FailingChromium())

        with tempfile.TemporaryDirectory() as temporary_directory:
            with self.assertRaises(collector.CollectionError) as caught:
                collector.collect_activities(
                    profile_dir=Path(temporary_directory) / "profile",
                    playwright_factory=lambda: manager,
                    status=lambda message: None,
                )

        message = str(caught.exception)
        self.assertIn("browser automation failed", message)
        self.assertNotIn("secret", message)


if __name__ == "__main__":
    unittest.main()
