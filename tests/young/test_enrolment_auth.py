from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from ustc_assistant.common.auth import (
    LoginCredentials,
    UserActionRequired,
    profile_dir_for_account,
)
from ustc_assistant.sources.young import enrolment as collector


class FakeRequest:
    method = "GET"


class FakeResponse:
    def __init__(self, payload, *, status: int = 200):
        self.url = (
            "https://young.ustc.edu.cn/login/wisdom-group-learning-bg/"
            "mobile/item/enrolmentList?_t=redacted&requestParams=redacted"
        )
        self.status = status
        self.request = FakeRequest()
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
    def __init__(self, page, selector=None, *, visible: bool = True):
        self.page = page
        self.selector = selector
        self.visible = visible
        self.clicks = 0
        self.first = self

    def is_visible(self):
        return self.visible

    def click(self):
        self.clicks += 1

    def fill(self, value):
        self.page.fills.append((self.selector, value))

    def count(self):
        return 1 if self.visible else 0

    def get_attribute(self, name):
        if name == "data-ustc-account":
            return getattr(self.page, "account_value", None)
        return None

    def input_value(self):
        return getattr(self.page, "account_value", None)


class FakePage:
    def __init__(self, responses):
        self.url = "about:blank"
        self.responses = list(responses)
        self.goto_calls = []
        self.clicks = []
        self.fills = []
        self.tab = FakeLocator(self, visible=True)
        self.next_button = FakeLocator(self, "li.ant-pagination-next")
        self.account_value = "PB00000000"
        self._eval_values: list[str] | None = None

    def goto(self, url, **kwargs):
        self.goto_calls.append((url, kwargs))
        self.url = url

    def get_by_text(self, text, **kwargs):
        if text != "报名中" or not kwargs.get("exact"):
            raise AssertionError("unexpected text locator")
        return self.tab

    def locator(self, selector):
        if selector == "li.ant-pagination-next":
            return self.next_button
        return FakeLocator(self, selector)

    def expect_response(self, predicate, **kwargs):
        if not self.responses:
            raise AssertionError("no fake response remains")
        response = self.responses.pop(0)
        if not predicate(response):
            raise AssertionError("response predicate rejected enrolmentList")
        return FakeExpectedResponse(response)

    def wait_for_timeout(self, timeout):
        return None

    def evaluate(self, script):
        return self._eval_values if self._eval_values is not None else []


class UnauthenticatedPage(FakePage):
    """A page stuck on the USTC CAS login origin (calendar never appears)."""

    def goto(self, url, **kwargs):
        self.goto_calls.append((url, kwargs))
        self.url = "https://id.ustc.edu.cn/cas/login?service=redacted"
        self.tab.visible = False


class AuthenticatedAfterLoginPage(FakePage):
    """Simulates the interactive login: goto lands on CAS, fill_ustc_login fills
    the username, then after a poll the page lands on SignUp with the tab visible
    and the expected account present for verification."""

    def __init__(self, responses):
        super().__init__(responses)
        self.tab.visible = False
        self.account_value = "PB00000000"
        self._filled_username = False

    def goto(self, url, **kwargs):
        self.goto_calls.append((url, kwargs))
        # First navigation lands on the CAS login origin.
        self.url = "https://id.ustc.edu.cn/cas/login?service=redacted"

    def wait_for_timeout(self, timeout):
        # After credentials are filled, the browser completes login and the
        # second-classroom SignUp page renders the "报名中" tab.
        if not self._filled_username and any(
            value == "PB00000000" for _selector, value in self.fills
        ):
            self._filled_username = True
        if self._filled_username and not self.tab.visible:
            self.url = (
                "https://young.ustc.edu.cn/login/"
                "sc-wisdom-group-learning/myproject/SignUp"
            )
            self.tab.visible = True


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


def fake_factory_for(page):
    context = FakeBrowserContext(page)
    chromium = FakeChromium(context)
    manager = FakePlaywrightManager(chromium)
    return lambda: manager, chromium, context


class BackgroundAuthTests(unittest.TestCase):
    def test_background_collection_requires_user_action_without_visible_window(self):
        page = UnauthenticatedPage([])
        factory, chromium, _ = fake_factory_for(page)

        with self.assertRaises(UserActionRequired):
            collector.collect_activities(
                account_id="local-account",
                allow_interactive_login=False,
                credentials=LoginCredentials("PB00000000"),
                playwright_factory=factory,
                status=lambda message: None,
            )

        self.assertTrue(chromium.launch_calls[0][1]["headless"])
        self.assertEqual(1, len(page.goto_calls))

    def test_headless_mode_does_not_fill_credentials_before_raising(self):
        # In headless/background mode the collector raises UserActionRequired
        # without attempting to fill the CAS form, mirroring the schedule
        # collector: autofill is an interactive-mode convenience only.
        page = UnauthenticatedPage([])
        factory, chromium, _ = fake_factory_for(page)

        with self.assertRaises(UserActionRequired):
            collector.collect_activities(
                account_id="local-account",
                allow_interactive_login=False,
                credentials=LoginCredentials("PB00000000", "secret"),
                playwright_factory=factory,
                status=lambda message: None,
            )

        self.assertTrue(chromium.launch_calls[0][1]["headless"])
        self.assertEqual([], page.fills)

    def test_uses_account_specific_profile_directory(self):
        page_one = UnauthenticatedPage([])
        factory_one, chromium_one, _ = fake_factory_for(page_one)
        page_two = UnauthenticatedPage([])
        factory_two, chromium_two, _ = fake_factory_for(page_two)

        for factory, chromium in (
            (factory_one, chromium_one),
            (factory_two, chromium_two),
        ):
            with self.assertRaises(UserActionRequired):
                collector.collect_activities(
                    account_id="local-account",
                    allow_interactive_login=False,
                    credentials=LoginCredentials("PB00000000"),
                    playwright_factory=factory,
                    status=lambda message: None,
                )

        first_profile = chromium_one.launch_calls[0][0]
        second_profile = chromium_two.launch_calls[0][0]
        self.assertEqual(
            str(profile_dir_for_account("local-account")),
            first_profile,
        )
        self.assertEqual(first_profile, second_profile)

        page_other = UnauthenticatedPage([])
        factory_other, chromium_other, _ = fake_factory_for(page_other)
        with self.assertRaises(UserActionRequired):
            collector.collect_activities(
                account_id="other-account",
                allow_interactive_login=False,
                credentials=LoginCredentials("PB11111111"),
                playwright_factory=factory_other,
                status=lambda message: None,
            )
        self.assertNotEqual(
            chromium_other.launch_calls[0][0],
            chromium_one.launch_calls[0][0],
        )

    def test_explicit_profile_dir_takes_precedence_over_account_id(self):
        page = UnauthenticatedPage([])
        factory, chromium, _ = fake_factory_for(page)

        with self.assertRaises(UserActionRequired):
            collector.collect_activities(
                profile_dir=Path("explicit-profile"),
                account_id="local-account",
                allow_interactive_login=False,
                credentials=LoginCredentials("PB00000000"),
                playwright_factory=factory,
                status=lambda message: None,
            )

        self.assertEqual(
            str(Path("explicit-profile")),
            chromium.launch_calls[0][0],
        )


class InteractiveAuthTests(unittest.TestCase):
    def test_interactive_login_resumes_after_credentials_filled(self):
        page = AuthenticatedAfterLoginPage(
            [FakeResponse(page_payload([{"id": "a"}], total=1, pages=1))]
        )
        factory, chromium, context = fake_factory_for(page)

        result = collector.collect_activities(
            account_id="local-account",
            allow_interactive_login=True,
            credentials=LoginCredentials("PB00000000", "secret"),
            login_timeout_ms=60_000,
            playwright_factory=factory,
            status=lambda message: None,
        )

        self.assertEqual("a", result.records[0]["id"])
        self.assertFalse(chromium.launch_calls[0][1]["headless"])
        self.assertTrue(context.closed)

    def test_visible_mode_without_credentials_still_collects(self):
        page = FakePage(
            [FakeResponse(page_payload([{"id": "a"}], total=1, pages=1))]
        )
        factory, chromium, context = fake_factory_for(page)

        result = collector.collect_activities(
            account_id="local-account",
            allow_interactive_login=True,
            credentials=None,
            playwright_factory=factory,
            status=lambda message: None,
        )

        self.assertEqual("a", result.records[0]["id"])
        self.assertFalse(chromium.launch_calls[0][1]["headless"])

    def test_legacy_profile_dir_only_call_preserves_visible_behavior(self):
        page = FakePage(
            [FakeResponse(page_payload([{"id": "a"}], total=1, pages=1))]
        )
        factory, chromium, context = fake_factory_for(page)

        with tempfile.TemporaryDirectory() as directory:
            profile = Path(directory) / "profile"
            result = collector.collect_activities(
                profile_dir=profile,
                playwright_factory=factory,
                status=lambda message: None,
            )

        self.assertEqual("a", result.records[0]["id"])
        self.assertEqual(str(profile), chromium.launch_calls[0][0])
        self.assertFalse(chromium.launch_calls[0][1]["headless"])
        self.assertTrue(context.closed)


class CancellationTests(unittest.TestCase):
    def test_cancellation_is_honored_during_login_wait(self):
        # In interactive mode the login-wait loop polls until cancelled; the
        # cancel_check is consulted before each poll so a cancelled collection
        # surfaces as CollectionCancelled rather than waiting for the timeout.
        page = UnauthenticatedPage([])
        factory, _chromium, _ = fake_factory_for(page)
        checks = {"count": 0}

        def cancel_check():
            checks["count"] += 1
            return checks["count"] >= 2

        from ustc_assistant.common.auth import CollectionCancelled

        with self.assertRaises(CollectionCancelled):
            collector.collect_activities(
                account_id="local-account",
                allow_interactive_login=True,
                credentials=LoginCredentials("PB00000000"),
                cancel_check=cancel_check,
                login_timeout_ms=60_000,
                playwright_factory=factory,
                status=lambda message: None,
            )

        self.assertGreaterEqual(checks["count"], 2)


class NoSecretLeakTests(unittest.TestCase):
    def test_user_action_error_message_contains_no_credentials(self):
        page = UnauthenticatedPage([])
        factory, _chromium, _ = fake_factory_for(page)

        with self.assertRaises(UserActionRequired) as caught:
            collector.collect_activities(
                account_id="local-account",
                allow_interactive_login=False,
                credentials=LoginCredentials("PB00000000", "secret-password"),
                playwright_factory=factory,
                status=lambda message: None,
            )

        message = str(caught.exception)
        self.assertNotIn("secret-password", message)
        self.assertNotIn("PB00000000", message)

    def test_normalized_snapshot_carries_no_account_or_password(self):
        raw = collector.CollectedEnrolmentActivities(
            records=(
                {
                    "id": "activity-1",
                    "itemName": "sample",
                    "baseContent": "<p>Description</p>",
                    "userId": "private-account-id",
                },
            ),
            reported_total=1,
            pages=1,
        )
        normalized, _ = collector.collect_enrolment_snapshot(
            collect_fn=lambda **kwargs: raw,
            collected_at="2026-07-22T08:00:00+08:00",
        )

        import json

        serialized = json.dumps(normalized, ensure_ascii=False)
        self.assertNotIn("private-account-id", serialized)
        self.assertNotIn("PB00000000", serialized)
        self.assertNotIn("password", serialized)
        # descriptionHtml must be converted to bounded plain text (no raw HTML tags).
        self.assertNotIn("descriptionHtml", normalized["activities"][0])
        self.assertNotIn("<p>", serialized)


if __name__ == "__main__":
    unittest.main()
