"""Versioned, bounded Bridge protocol primitives."""

from __future__ import annotations

import json
import secrets
from typing import Any


PROTOCOL_VERSION = "1.0"
QUERY_PROTOCOL_VERSION = "1.0"
MAX_REQUEST_BYTES = 64 * 1024


class ProtocolError(ValueError):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def make_handshake(*, port: int, pid: int) -> dict[str, Any]:
    return {
        "protocolVersion": PROTOCOL_VERSION,
        "port": port,
        "token": secrets.token_urlsafe(32),
        "pid": pid,
    }


def parse_request_body(
    body: bytes, *, declared_length: int
) -> dict[str, Any]:
    if declared_length > MAX_REQUEST_BYTES or len(body) > MAX_REQUEST_BYTES:
        raise ProtocolError("too_large")
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise ProtocolError("invalid_json") from None
    if not isinstance(payload, dict):
        raise ProtocolError("invalid_json")
    if payload.get("protocolVersion") != PROTOCOL_VERSION:
        raise ProtocolError("unsupported_version")
    return payload
