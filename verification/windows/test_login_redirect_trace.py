import json
import unittest

from login_redirect_trace import RedirectTraceCollector, UrlProjector


class FakeEvents:
    def __init__(self):
        self.handlers = {}

    def on(self, event, callback):
        self.handlers.setdefault(event, []).append(callback)

    def emit(self, event, value):
        for callback in self.handlers.get(event, []):
            callback(value)


class FakePage(FakeEvents):
    def __init__(self):
        super().__init__()
        self.main_frame = FakeFrame(self)

    @property
    def url(self):
        raise AssertionError("the collector must not read page.url")

    def close(self):
        self.emit("close", None)


class FakeFrame:
    def __init__(self, page):
        self.page = page
        self.url = "about:blank"


class FakeRequest:
    def __init__(self, url, *, method="GET", frame=None, redirected_from=None):
        self.url = url
        self.method = method
        self.resource_type = "document"
        self.frame = frame
        self.redirected_from = redirected_from

    @property
    def headers(self):
        raise AssertionError("request headers must not be read")

    def all_headers(self):
        raise AssertionError("all_headers must not be called")

    @property
    def post_data(self):
        raise AssertionError("request body must not be read")

    @property
    def post_data_buffer(self):
        raise AssertionError("request body bytes must not be read")

    @property
    def failure(self):
        raise AssertionError("raw request failure text must not be read")


class FakeResponse:
    def __init__(self, request, status):
        self.request = request
        self.status = status

    @property
    def headers(self):
        raise AssertionError("response headers must not be read")

    def all_headers(self):
        raise AssertionError("response all_headers must not be called")

    def body(self):
        raise AssertionError("response body must not be read")

    def text(self):
        raise AssertionError("response text must not be read")


class BrokenFrameRequest(FakeRequest):
    def __init__(self, url, *, method="GET", redirected_from=None):
        self.url = url
        self.method = method
        self.resource_type = "document"
        self.redirected_from = redirected_from

    @property
    def frame(self):
        raise RuntimeError("frame is unavailable for this document request")


class RedirectTraceTests(unittest.TestCase):
    def test_url_projection_removes_secrets_and_keeps_only_known_keys(self):
        projector = UrlProjector("young")
        projected = projector.project(
            "https://person:pass@young.ustc.edu.cn/login/"
            "private-route?ticket=TICKET_SENTINEL&service=https%3A%2F%2Fsecret.example"
            "&secretKey=KEY_SENTINEL#FRAGMENT_SENTINEL"
        )

        serialized = json.dumps(projected)
        for secret in ("person", "pass", "private-route", "TICKET_SENTINEL", "secret.example", "KEY_SENTINEL", "FRAGMENT_SENTINEL"):
            self.assertNotIn(secret, serialized)
        self.assertEqual(projected["origin"], "https://young.ustc.edu.cn")
        self.assertEqual(projected["path"], "/login/<segment>")
        self.assertEqual(projected["query_keys"], ["ticket", "service"])
        self.assertEqual(projected["unknown_query_key_count"], 1)

    def test_unknown_hosts_and_query_names_are_anonymized(self):
        projector = UrlProjector("young")
        first = projector.project("https://host-secret.example/private-a?privateKey=VALUE_A")
        second = projector.project("https://second-secret.example/private-b?privateToken=VALUE_B")

        serialized = json.dumps([first, second])
        for secret in ("host-secret", "second-secret", "private-a", "private-b", "privateKey", "privateToken", "VALUE_A", "VALUE_B"):
            self.assertNotIn(secret, serialized)
        self.assertEqual(first["origin"], "unknown_origin_1")
        self.assertEqual(second["origin"], "unknown_origin_2")
        self.assertNotEqual(first["path_id"], second["path_id"])
        self.assertEqual(
            first["path_id"],
            projector.project("https://host-secret.example/private-a?ticket=ANOTHER_VALUE")["path_id"],
        )
        self.assertEqual(first["unknown_query_key_count"], 1)
        self.assertEqual(second["unknown_query_key_count"], 1)

    def test_redirect_status_and_request_sequence_are_associated(self):
        context = FakeEvents()
        page = FakePage()
        collector = RedirectTraceCollector("young")
        collector.attach(context)
        collector.attach_page(page)

        first = FakeRequest(
            "https://young.ustc.edu.cn/login?ticket=PRIVATE_TICKET",
            method="POST",
            frame=page.main_frame,
        )
        second = FakeRequest(
            "https://id.ustc.edu.cn/cas/login?RelayState=PRIVATE_STATE",
            frame=page.main_frame,
            redirected_from=first,
        )
        context.emit("request", first)
        context.emit("response", FakeResponse(first, 302))
        context.emit("request", second)
        context.emit("response", FakeResponse(second, 200))

        records = collector.result()["records"]
        self.assertEqual([record["status"] for record in records], [302, 200])
        self.assertEqual([record["method"] for record in records], ["POST", "GET"])
        self.assertIsNone(records[0]["redirect_from_seq"])
        self.assertEqual(records[1]["redirect_from_seq"], records[0]["request_seq"])
        self.assertNotIn("PRIVATE_TICKET", json.dumps(records))
        self.assertNotIn("PRIVATE_STATE", json.dumps(records))

    def test_popup_request_without_frame_keeps_redirect_and_status(self):
        context = FakeEvents()
        collector = RedirectTraceCollector("young")
        collector.attach(context)
        first = FakeRequest("https://young.ustc.edu.cn/login")
        popup_request = BrokenFrameRequest(
            "https://id.ustc.edu.cn/cas/login?ticket=PRIVATE_POPUP_TICKET",
            redirected_from=first,
        )
        context.emit("request", first)
        context.emit("response", FakeResponse(first, 302))
        context.emit("request", popup_request)
        context.emit("response", FakeResponse(popup_request, 200))

        records = collector.result()["records"]
        self.assertEqual(records[1]["page_seq"], 0)
        self.assertEqual(records[1]["frame_seq"], 0)
        self.assertEqual(records[1]["redirect_from_seq"], records[0]["request_seq"])
        self.assertEqual(records[1]["status"], 200)
        self.assertNotIn("PRIVATE_POPUP_TICKET", json.dumps(records))

    def test_request_failure_uses_closed_code_without_reading_raw_failure(self):
        context = FakeEvents()
        collector = RedirectTraceCollector("young")
        collector.attach(context)
        request = FakeRequest("https://young.ustc.edu.cn/login")

        context.emit("request", request)
        context.emit("requestfailed", request)

        result = collector.result()
        self.assertEqual(result["failure"], {"code": "document_request_failed"})
        self.assertEqual(result["records"][0]["failure"], "request_failed")

    def test_frame_navigation_and_popup_use_anonymous_sequences(self):
        context = FakeEvents()
        page = FakePage()
        popup = FakePage()
        collector = RedirectTraceCollector("young")
        collector.attach(context)
        collector.attach_page(page)

        page.main_frame.url = "https://young.ustc.edu.cn/login?ticket=FRAME_SECRET"
        page.emit("framenavigated", page.main_frame)
        page.emit("popup", popup)

        records = collector.result()["records"]
        self.assertEqual(records[0]["kind"], "frame_navigated")
        self.assertEqual(records[0]["page_seq"], 1)
        self.assertEqual(records[0]["frame_seq"], 1)
        self.assertEqual(records[1]["kind"], "popup")
        self.assertEqual(records[1]["page_seq"], 2)
        self.assertEqual(records[1]["opener_page_seq"], 1)
        self.assertNotIn("FRAME_SECRET", json.dumps(records))

    def test_closing_last_page_signals_shutdown_without_failure(self):
        page = FakePage()
        closed = []
        collector = RedirectTraceCollector("young")
        collector.set_all_pages_closed_callback(lambda: closed.append(True))
        collector.attach_page(page)

        page.close()

        self.assertEqual(closed, [True])
        self.assertIsNone(collector.result()["failure"])

    def test_event_limit_and_damaged_url_return_closed_metadata(self):
        context = FakeEvents()
        collector = RedirectTraceCollector("young", max_events=1)
        collector.attach(context)
        context.emit("request", FakeRequest("https://young.ustc.edu.cn/login"))
        context.emit("request", FakeRequest("https://young.ustc.edu.cn/cas/login"))
        result = collector.result()

        invalid = UrlProjector("jw").project("http://[broken-secret-host")
        self.assertTrue(result["truncated"])
        self.assertEqual(len(result["records"]), 1)
        self.assertEqual(invalid["invalid"], True)
        self.assertEqual(invalid["origin"], "invalid_origin")
        self.assertNotIn("broken-secret-host", json.dumps(invalid))


if __name__ == "__main__":
    unittest.main()
