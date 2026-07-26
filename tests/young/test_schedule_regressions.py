from __future__ import annotations

import os
import tempfile
import unittest
from datetime import date
from pathlib import Path
from unittest.mock import patch

from ustc_assistant.sources.young import schedule as collector

ROOT = Path(__file__).resolve().parents[2]


class FakeRequest:
    method = "GET"


class FakeResponse:
    def __init__(self, payload, *, status=200):
        self.url = (
            "https://young.ustc.edu.cn/login/wisdom-group-learning-bg/"
            "personal/scCalendar/getPageUserList?_t=redacted&requestParams=redacted"
        )
        self.status = status
        self.request = FakeRequest()
        self._payload = payload

    def json(self):
        return self._payload


def page_payload(records, *, total=None, pages=None):
    count = len(records) if total is None else total
    page_count = (1 if count else 0) if pages is None else pages
    return {
        "success": True,
        "code": 200,
        "result": {
            "records": records,
            "total": count,
            "size": 10,
            "current": 1,
            "pages": page_count,
        },
    }


def schedule_record(schedule_id, day):
    return {
        "id": schedule_id,
        "itemId": f"activity-{schedule_id}",
        "title": f"Activity {schedule_id}",
        "startTime": f"{day} 16:00:00",
        "endTime": f"{day} 17:30:00",
        "place": "Sample room",
        "content": "<p>Sample</p>",
    }


class FakeExpectedResponse:
    def __init__(self, response):
        self.value = response

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False


class FakeLocator:
    def __init__(self, page, selector, *, visible=True):
        self.page = page
        self.selector = selector
        self.visible = visible

    def is_visible(self):
        return self.visible

    def wait_for(self, **kwargs):
        if not self.visible:
            raise collector.PlaywrightTimeoutError("not visible")

    def click(self):
        if not self.visible:
            raise collector.PlaywrightTimeoutError("not visible")
        self.page.clicks.append(self.selector)

    def nth(self, index):
        return FakeLocator(self.page, f"{self.selector}:nth({index})")

    def filter(self, **kwargs):
        return FakeLocator(self.page, f"{self.selector}:text({kwargs['has_text']})")


class FakePage:
    def __init__(self, responses):
        self.url = "about:blank"
        self.responses = list(responses)
        self.goto_calls = []
        self.clicks = []

    def goto(self, url, **kwargs):
        self.goto_calls.append((url, kwargs))
        self.url = url

    def locator(self, selector):
        return FakeLocator(self, selector)

    def expect_response(self, predicate, **kwargs):
        response = self.responses.pop(0)
        if not predicate(response):
            raise AssertionError("response predicate rejected schedule response")
        return FakeExpectedResponse(response)

    def wait_for_timeout(self, timeout):
        return None


class SelectOnlyCalendarPage(FakePage):
    def locator(self, selector):
        hidden = selector in {
            collector.PREVIOUS_MONTH_SELECTOR,
            collector.NEXT_MONTH_SELECTOR,
        }
        return FakeLocator(self, selector, visible=not hidden)


class MissingDateCellPage(FakePage):
    def locator(self, selector):
        if selector.startswith("td.ant-fullcalendar-cell"):
            return FakeLocator(self, selector, visible=False)
        return FakeLocator(self, selector)


class UnauthenticatedPage(FakePage):
    def goto(self, url, **kwargs):
        self.goto_calls.append((url, kwargs))
        self.url = "https://id.ustc.edu.cn/cas/login?service=redacted"

    def locator(self, selector):
        if selector == collector.CALENDAR_SELECTOR:
            return FakeLocator(self, selector, visible=False)
        return FakeLocator(self, selector)


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
        self.assertIsNotNone(collector, "schedule collector must exist")


@unittest.skipIf(collector is None, "collector module not implemented yet")
class DateWindowTests(unittest.TestCase):
    def test_uses_inclusive_seven_day_and_calendar_month_window(self):
        start, end = collector.query_window(date(2026, 7, 21))

        self.assertEqual(date(2026, 7, 14), start)
        self.assertEqual(date(2026, 8, 21), end)
        self.assertEqual(39, len(tuple(collector.iter_dates(start, end))))

    def test_calendar_month_clamps_to_target_month_end(self):
        self.assertEqual(
            date(2026, 2, 28), collector.add_calendar_month(date(2026, 1, 31))
        )
        self.assertEqual(
            date(2024, 2, 29), collector.add_calendar_month(date(2024, 1, 31))
        )
        self.assertEqual(
            date(2027, 1, 31), collector.add_calendar_month(date(2026, 12, 31))
        )

    def test_click_target_is_the_interactive_date_inside_the_matching_cell(self):
        self.assertEqual(
            'td.ant-fullcalendar-cell[title="2026年7月14日"] '
            ".ant-fullcalendar-date",
            collector.date_cell_selector(date(2026, 7, 14)),
        )


@unittest.skipIf(collector is None, "collector module not implemented yet")
class ResponseContractTests(unittest.TestCase):
    def test_matches_only_exact_read_only_schedule_response(self):
        response = FakeResponse(page_payload([]))
        self.assertTrue(collector.is_schedule_list_response(response))

        response.url = response.url.replace("young.ustc.edu.cn", "example.edu")
        self.assertFalse(collector.is_schedule_list_response(response))
        response.url = (
            "https://young.ustc.edu.cn/login/wisdom-group-learning-bg/"
            "personal/scCalendar/getPageUserList/x?requestParams=redacted"
        )
        self.assertFalse(collector.is_schedule_list_response(response))
        response.request.method = "POST"
        self.assertFalse(collector.is_schedule_list_response(response))

    def test_rejects_multi_page_day_instead_of_returning_partial_data(self):
        response = FakeResponse(
            page_payload([schedule_record("a", "2026-07-21")], total=11, pages=2)
        )

        with self.assertRaisesRegex(collector.CollectionError, "more than one page"):
            collector.parse_schedule_page(response, date(2026, 7, 21))

    def test_accepts_an_empty_day(self):
        result = collector.parse_schedule_page(
            FakeResponse(page_payload([])), date(2026, 7, 21)
        )

        self.assertEqual((), result.records)
        self.assertEqual(0, result.total)

    def test_rejects_record_outside_selected_day(self):
        response = FakeResponse(
            page_payload([schedule_record("a", "2026-07-22")])
        )

        with self.assertRaisesRegex(collector.CollectionError, "selected date"):
            collector.parse_schedule_page(response, date(2026, 7, 21))


@unittest.skipIf(collector is None, "collector module not implemented yet")
class BrowserFlowTests(unittest.TestCase):
    def test_background_collection_requires_user_action_without_visible_window(self):
        page = UnauthenticatedPage([])
        context = FakeBrowserContext(page)
        chromium = FakeChromium(context)
        manager = FakePlaywrightManager(chromium)

        with tempfile.TemporaryDirectory() as temporary_directory:
            with self.assertRaises(collector.UserActionRequired):
                collector.collect_schedules(
                    profile_dir=Path(temporary_directory) / "profile",
                    today=date(2026, 7, 21),
                    allow_interactive_login=False,
                    playwright_factory=lambda: manager,
                    status=lambda message: None,
                )

        self.assertTrue(chromium.launch_calls[0][1]["headless"])
        self.assertEqual(1, len(page.goto_calls))

    def test_reports_missing_calendar_cell_separately_from_response_timeout(self):
        page = MissingDateCellPage([])

        with self.assertRaisesRegex(
            collector.CollectionError, "calendar cell.*was not found"
        ):
            collector.collect_from_page(
                page,
                today=date(2026, 7, 21),
                queried_from=date(2026, 7, 14),
                queried_through=date(2026, 7, 14),
                status=lambda message: None,
            )

    def test_collects_each_day_across_month_boundary_and_deduplicates(self):
        duplicate = schedule_record("same", "2026-07-31")
        responses = [
            FakeResponse(page_payload([duplicate])),
            FakeResponse(page_payload([])),
            FakeResponse(page_payload([schedule_record("b", "2026-08-02")])),
        ]
        page = FakePage(responses)

        result = collector.collect_from_page(
            page,
            today=date(2026, 7, 31),
            queried_from=date(2026, 7, 31),
            queried_through=date(2026, 8, 2),
            status=lambda message: None,
        )

        self.assertEqual(("same", "b"), tuple(r["id"] for r in result.records))
        self.assertEqual(3, result.queried_dates)
        self.assertEqual(1, result.empty_dates)
        self.assertEqual(
            (
                collector.ScheduleDateCheck(date(2026, 7, 31), False),
                collector.ScheduleDateCheck(date(2026, 8, 1), True),
                collector.ScheduleDateCheck(date(2026, 8, 2), False),
            ),
            result.date_checks,
        )
        self.assertIn(collector.NEXT_MONTH_SELECTOR, page.clicks)
        self.assertIn(
            collector.date_cell_selector(date(2026, 8, 2)), page.clicks
        )

    def test_uses_ant_calendar_year_and_month_selects_when_arrows_are_absent(self):
        page = SelectOnlyCalendarPage(
            [FakeResponse(page_payload([schedule_record("a", "2027-01-01")]))]
        )

        collector.collect_from_page(
            page,
            today=date(2026, 12, 31),
            queried_from=date(2027, 1, 1),
            queried_through=date(2027, 1, 1),
            status=lambda message: None,
        )

        self.assertIn(collector.YEAR_SELECT_SELECTOR, page.clicks)
        self.assertIn(collector.MONTH_SELECT_SELECTOR, page.clicks)
        self.assertIn(
            f"{collector.VISIBLE_OPTION_SELECTOR}:text(2027)", page.clicks
        )
        self.assertIn(
            f"{collector.VISIBLE_OPTION_SELECTOR}:nth(0)", page.clicks
        )

    def test_rejects_conflicting_duplicate_schedule_id(self):
        first = schedule_record("same", "2026-07-21")
        first["endTime"] = "2026-07-22 17:30:00"
        second = dict(first, title="Changed")
        page = FakePage(
            [FakeResponse(page_payload([first])), FakeResponse(page_payload([second]))]
        )

        with self.assertRaisesRegex(collector.CollectionError, "conflicting duplicate"):
            collector.collect_from_page(
                page,
                today=date(2026, 7, 21),
                queried_from=date(2026, 7, 21),
                queried_through=date(2026, 7, 22),
                status=lambda message: None,
            )

    def test_cancellation_is_checked_before_each_selected_date(self):
        page = FakePage(
            [
                FakeResponse(page_payload([])),
                FakeResponse(page_payload([])),
            ]
        )
        checks = 0

        def cancel_check():
            nonlocal checks
            checks += 1
            return checks == 3

        with self.assertRaises(collector.CollectionCancelled):
            collector.collect_from_page(
                page,
                today=date(2026, 7, 21),
                queried_from=date(2026, 7, 21),
                queried_through=date(2026, 7, 22),
                cancel_check=cancel_check,
                status=lambda message: None,
            )

        self.assertEqual(1, len(page.responses))

    def test_uses_shared_visible_edge_profile_and_closes_context(self):
        day = date(2026, 7, 21)
        page = FakePage([FakeResponse(page_payload([]))])
        context = FakeBrowserContext(page)
        chromium = FakeChromium(context)
        manager = FakePlaywrightManager(chromium)

        with tempfile.TemporaryDirectory() as temporary_directory:
            profile = Path(temporary_directory) / "profile"
            collector.collect_schedules(
                profile_dir=profile,
                today=day,
                queried_from=day,
                queried_through=day,
                playwright_factory=lambda: manager,
                status=lambda message: None,
            )

        launched_profile, options = chromium.launch_calls[0]
        self.assertEqual(str(profile), launched_profile)
        self.assertEqual("msedge", options["channel"])
        self.assertFalse(options["headless"])
        self.assertTrue(context.closed)

    def test_default_profile_matches_existing_collectors(self):
        local_app_data = Path("C:/Users/Sample/AppData/Local")
        with patch.dict(os.environ, {"LOCALAPPDATA": str(local_app_data)}):
            profile = collector.default_profile_dir()

        self.assertEqual(
            local_app_data / "USTC Campus Assistant" / "edge-profile", profile
        )


if __name__ == "__main__":
    unittest.main()
