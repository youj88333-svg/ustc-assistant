from __future__ import annotations

import unittest

from ustc_assistant.bridge.protocol import (
    MAX_REQUEST_BYTES,
    PROTOCOL_VERSION,
    ProtocolError,
    make_handshake,
    parse_request_body,
)


class HandshakeTests(unittest.TestCase):
    def test_handshake_token_is_random_and_url_safe(self):
        first = make_handshake(port=12001, pid=10)
        second = make_handshake(port=12002, pid=11)

        self.assertNotEqual(first["token"], second["token"])
        self.assertRegex(first["token"], r"^[A-Za-z0-9_-]{43}$")
        self.assertEqual(PROTOCOL_VERSION, first["protocolVersion"])

    def test_request_body_rejects_invalid_size_json_and_version(self):
        with self.assertRaisesRegex(ProtocolError, "too_large"):
            parse_request_body(b"{}", declared_length=MAX_REQUEST_BYTES + 1)
        with self.assertRaisesRegex(ProtocolError, "invalid_json"):
            parse_request_body(b"{", declared_length=1)
        with self.assertRaisesRegex(ProtocolError, "unsupported_version"):
            parse_request_body(
                b'{"protocolVersion":"9.0"}',
                declared_length=25,
            )


if __name__ == "__main__":
    unittest.main()
