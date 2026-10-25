#!/usr/bin/env python3
"""Local-only HTTPS and HTTP/3 WebTransport synthetic fixture."""

from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import ipaddress
import json
import logging
import os
import re
import socket
import ssl
import stat
import sys
import tempfile
import threading
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Optional


FIXTURE_VERSION = 1
HTTPS_BODY = b'{"fixture":"https-fixture","version":1,"result":"synthetic-ok"}'
WT_DATAGRAM = b"fixture-datagram-v1"
WT_DATAGRAM_ECHO = b"fixture-datagram-v1-echo"
MAX_CONTROL_LINE = 4096
MAX_HTTP_LINE = 8192
MAX_HTTP_HEADER_BYTES = 32768
MAX_HTTP_HEADER_LINES = 100
RUNTIME_LEAF_RE = re.compile(r"run-[A-Za-z0-9][A-Za-z0-9._-]{0,127}", re.IGNORECASE)

COUNTER_NAMES = (
    "https_get_query",
    "quic_udp_datagrams",
    "webtransport_connects",
    "webtransport_echoes",
)


class InvalidArguments(Exception):
    pass


class InvalidRuntimeRoot(Exception):
    pass


class InvalidDepsRoot(Exception):
    pass


class InvalidControl(Exception):
    pass


@dataclass(frozen=True)
class TempFile:
    path: Path
    identity: tuple[int, int]


def _norm_path(value: os.PathLike[str] | str) -> str:
    return os.path.normcase(os.path.normpath(os.path.abspath(os.fspath(value))))


def _is_strict_child(base: Path, child: Path) -> bool:
    base_s = _norm_path(base)
    child_s = _norm_path(child)
    try:
        return child_s != base_s and os.path.commonpath((base_s, child_s)) == base_s
    except ValueError:
        return False


def _chain_paths(path: Path) -> list[Path]:
    absolute = Path(os.path.abspath(os.fspath(path)))
    parts = absolute.parts
    if not parts:
        return []
    current = Path(parts[0])
    result = [current]
    for part in parts[1:]:
        current = current / part
        result.append(current)
    return result


def _reject_reparse_chain(path: Path, error_type: type[Exception]) -> None:
    reparse_flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    for component in _chain_paths(path):
        try:
            info = component.lstat()
        except OSError as exc:
            raise error_type() from exc
        attributes = getattr(info, "st_file_attributes", 0)
        if stat.S_ISLNK(info.st_mode) or attributes & reparse_flag:
            raise error_type()


def _canonical_existing_directory(raw: str, base: Path, error_type: type[Exception]) -> Path:
    candidate = Path(os.path.abspath(raw))
    if not _is_strict_child(base, candidate):
        raise error_type()
    _reject_reparse_chain(candidate, error_type)
    try:
        if not stat.S_ISDIR(candidate.lstat().st_mode):
            raise error_type()
    except OSError as exc:
        raise error_type() from exc
    return candidate


def _validate_roots(runtime_raw: str, deps_raw: str) -> tuple[Path, Path]:
    script_path = Path(os.path.abspath(__file__))
    _reject_reparse_chain(script_path, InvalidRuntimeRoot)
    workspace = script_path.parents[2]
    runtime_base = workspace / "verification" / ".runtime"
    _reject_reparse_chain(runtime_base, InvalidRuntimeRoot)

    runtime_root = _canonical_existing_directory(runtime_raw, runtime_base, InvalidRuntimeRoot)
    if RUNTIME_LEAF_RE.fullmatch(runtime_root.name) is None:
        raise InvalidRuntimeRoot()

    deps_root = _canonical_existing_directory(deps_raw, runtime_base, InvalidDepsRoot)
    if _norm_path(runtime_root) == _norm_path(deps_root):
        raise InvalidDepsRoot()
    return runtime_root, deps_root


def _write_temp(runtime_root: Path, prefix: str, payload: bytes) -> TempFile:
    fd, raw_path = tempfile.mkstemp(prefix=prefix, suffix=".pem", dir=str(runtime_root))
    path = Path(raw_path)
    try:
        try:
            os.chmod(raw_path, 0o600)
        except OSError:
            # Windows ACLs govern access; chmod is best-effort there.
            pass
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            info = os.fstat(handle.fileno())
            identity = (int(info.st_dev), int(info.st_ino))
        return TempFile(path=path, identity=identity)
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            path.unlink()
        except OSError:
            pass
        raise


def _delete_own_temp(temp_file: Optional[TempFile]) -> None:
    if temp_file is None:
        return
    try:
        info = temp_file.path.lstat()
        reparse_flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
        if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & reparse_flag:
            return
        if (int(info.st_dev), int(info.st_ino)) != temp_file.identity:
            return
        temp_file.path.unlink()
    except FileNotFoundError:
        pass
    except OSError:
        # Startup does not proceed unless both credential files are gone.
        pass


def _build_certificate(runtime_root: Path) -> tuple[bytes, str, str, TempFile, TempFile]:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

    key = ec.generate_private_key(ec.SECP256R1())
    subject = x509.Name(
        [x509.NameAttribute(NameOID.COMMON_NAME, "127.0.0.1 synthetic fixture")]
    )
    now = datetime.now(timezone.utc)
    certificate = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before((now - timedelta(minutes=1)).replace(tzinfo=None))
        .not_valid_after((now + timedelta(days=6)).replace(tzinfo=None))
        .add_extension(
            x509.SubjectAlternativeName([x509.IPAddress(ipaddress.IPv4Address("127.0.0.1"))]),
            critical=False,
        )
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(
            x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False
        )
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
        .sign(key, hashes.SHA256())
    )
    cert_der = certificate.public_bytes(serialization.Encoding.DER)
    cert_pem = certificate.public_bytes(serialization.Encoding.PEM)
    key_pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    cert_temp: Optional[TempFile] = None
    key_temp: Optional[TempFile] = None
    try:
        cert_temp = _write_temp(runtime_root, ".fixture-cert-", cert_pem)
        key_temp = _write_temp(runtime_root, ".fixture-key-", key_pem)
    except BaseException:
        _delete_own_temp(key_temp)
        _delete_own_temp(cert_temp)
        raise
    fingerprint = hashlib.sha256(cert_der).digest()
    return (
        cert_der,
        base64.b64encode(fingerprint).decode("ascii"),
        fingerprint.hex(),
        cert_temp,
        key_temp,
    )


def _load_tls_material(runtime_root: Path) -> tuple[ssl.SSLContext, Any, str, str]:
    from aioquic.h3.connection import H3_ALPN
    from aioquic.quic.configuration import QuicConfiguration

    _, fingerprint_b64, fingerprint_hex, cert_temp, key_temp = _build_certificate(runtime_root)
    try:
        ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ssl_context.minimum_version = ssl.TLSVersion.TLSv1_3
        ssl_context.maximum_version = ssl.TLSVersion.TLSv1_3
        ssl_context.set_alpn_protocols(["http/1.1"])
        ssl_context.load_cert_chain(str(cert_temp.path), str(key_temp.path))

        quic_configuration = QuicConfiguration(
            alpn_protocols=H3_ALPN,
            is_client=False,
            max_datagram_frame_size=65536,
            max_datagram_size=1200,
            idle_timeout=30.0,
            quic_logger=None,
            secrets_log_file=None,
        )
        quic_configuration.load_cert_chain(str(cert_temp.path), str(key_temp.path))
    finally:
        _delete_own_temp(key_temp)
        _delete_own_temp(cert_temp)
    if cert_temp.path.exists() or key_temp.path.exists():
        raise OSError()
    return ssl_context, quic_configuration, fingerprint_b64, fingerprint_hex


class FixtureState:
    def __init__(self) -> None:
        self.counters = {name: 0 for name in COUNTER_NAMES}
        self.fault_types: set[str] = set()
        self.fault_contexts: set[str] = set()
        self.writers: set[asyncio.StreamWriter] = set()
        self.https_tasks: set[asyncio.Task[Any]] = set()

    def record_fault(self, exc: BaseException) -> None:
        name = type(exc).__name__
        if not name or re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,63}", name) is None:
            name = "Exception"
        self.fault_types.add(name)

    def record_fault_type(self, name: str) -> None:
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,63}", name):
            self.fault_types.add(name)
        else:
            self.fault_types.add("Exception")

    def snapshot(self) -> dict[str, int]:
        return {name: int(self.counters[name]) for name in COUNTER_NAMES}

    def reset(self) -> None:
        for name in COUNTER_NAMES:
            self.counters[name] = 0
        self.fault_types.clear()
        self.fault_contexts.clear()


def _http_response(status: int, body: bytes = b"") -> bytes:
    reasons = {200: b"OK", 204: b"No Content", 400: b"Bad Request", 404: b"Not Found"}
    reason = reasons.get(status, b"Not Found")
    headers = [
        b"HTTP/1.1 " + str(status).encode("ascii") + b" " + reason,
        b"Access-Control-Allow-Origin: *",
        b"Access-Control-Allow-Methods: GET, OPTIONS",
        b"Access-Control-Allow-Headers: *",
        b"Access-Control-Allow-Private-Network: true",
        b"Content-Type: application/json; charset=utf-8",
        b"Content-Length: " + str(len(body)).encode("ascii"),
        b"Connection: close",
        b"",
        b"",
    ]
    return b"\r\n".join(headers) + body


async def _handle_https(
    reader: asyncio.StreamReader, writer: asyncio.StreamWriter, state: FixtureState
) -> None:
    task = asyncio.current_task()
    if task is not None:
        state.https_tasks.add(task)
    state.writers.add(writer)
    response = _http_response(400)
    try:
        request_line = await asyncio.wait_for(reader.readline(), timeout=5.0)
        if not request_line or len(request_line) > MAX_HTTP_LINE or not request_line.endswith(b"\r\n"):
            return
        parts = request_line[:-2].split(b" ")
        if len(parts) != 3 or parts[2] not in (b"HTTP/1.0", b"HTTP/1.1"):
            return

        header_bytes = 0
        header_lines = 0
        while True:
            line = await asyncio.wait_for(reader.readline(), timeout=5.0)
            if not line or len(line) > MAX_HTTP_LINE or not line.endswith(b"\r\n"):
                return
            header_bytes += len(line)
            header_lines += 1
            if header_bytes > MAX_HTTP_HEADER_BYTES or header_lines > MAX_HTTP_HEADER_LINES:
                return
            if line == b"\r\n":
                break

        method, target, _ = parts
        if target == b"/query" and method == b"GET":
            state.counters["https_get_query"] += 1
            response = _http_response(200, HTTPS_BODY)
        elif target == b"/query" and method == b"OPTIONS":
            response = _http_response(204)
        else:
            response = _http_response(404)
        writer.write(response)
        await asyncio.wait_for(writer.drain(), timeout=5.0)
    except (asyncio.TimeoutError, asyncio.IncompleteReadError, ConnectionError, OSError):
        pass
    except Exception as exc:
        state.record_fault(exc)
    finally:
        try:
            writer.close()
            await asyncio.wait_for(writer.wait_closed(), timeout=1.0)
        except Exception as exc:
            if type(exc) not in (ConnectionResetError, asyncio.TimeoutError):
                state.record_fault(exc)
        state.writers.discard(writer)
        if task is not None:
            state.https_tasks.discard(task)


def _make_https_protocol_type(
    state: FixtureState, loop: asyncio.AbstractEventLoop
) -> type:
    class FixtureHTTPSProtocol(asyncio.StreamReaderProtocol):
        def __init__(self) -> None:
            reader = asyncio.StreamReader(limit=MAX_HTTP_LINE)
            super().__init__(
                reader,
                lambda stream_reader, stream_writer: _handle_https(
                    stream_reader, stream_writer, state
                ),
                loop=loop,
            )

        def connection_lost(self, exc: Optional[BaseException]) -> None:
            super().connection_lost(exc)
            closed = getattr(self, "_closed", None)
            close_error: Optional[BaseException] = None
            if closed is not None and closed.done() and not closed.cancelled():
                try:
                    close_error = closed.exception()
                except BaseException as consume_error:
                    state.record_fault(consume_error)

            # A TLS peer may abort after seeing the fixture's temporary
            # self-signed certificate. Consume StreamReaderProtocol's close
            # future here so asyncio does not report it as unhandled later.
            if type(exc) is ConnectionResetError and (
                close_error is None or type(close_error) is ConnectionResetError
            ):
                return
            if isinstance(close_error, BaseException):
                state.fault_contexts.add("https_protocol_close")
                state.record_fault(close_error)
            elif isinstance(exc, BaseException):
                state.fault_contexts.add("https_protocol_argument")
                state.record_fault(exc)

    return FixtureHTTPSProtocol


def _make_h3_protocol_type(state: FixtureState, h3_types: dict[str, Any]) -> type:
    base = h3_types["QuicConnectionProtocol"]
    h3_connection = h3_types["H3Connection"]
    h3_alpn = h3_types["H3_ALPN"]
    headers_received = h3_types["HeadersReceived"]
    datagram_received = h3_types["DatagramReceived"]
    protocol_negotiated = h3_types["ProtocolNegotiated"]

    class FixtureProtocol(base):
        def __init__(self, *args: Any, **kwargs: Any) -> None:
            super().__init__(*args, **kwargs)
            self._http: Any = None
            self._webtransport_sessions: set[int] = set()
            self._seen_headers: set[int] = set()

        def quic_event_received(self, event: Any) -> None:
            try:
                if isinstance(event, protocol_negotiated) and event.alpn_protocol in h3_alpn:
                    self._http = h3_connection(self._quic, enable_webtransport=True)
                if self._http is None:
                    return
                for http_event in self._http.handle_event(event):
                    self.http_event_received(http_event)
            except Exception as exc:
                state.record_fault(exc)
                try:
                    self.close()
                except Exception as close_exc:
                    state.record_fault(close_exc)

        def http_event_received(self, event: Any) -> None:
            try:
                if isinstance(event, headers_received):
                    self._headers_received(event)
                elif isinstance(event, datagram_received):
                    self._datagram_received(event)
            except Exception as exc:
                state.record_fault(exc)
                try:
                    self.close()
                except Exception as close_exc:
                    state.record_fault(close_exc)

        def _headers_received(self, event: Any) -> None:
            stream_id = int(event.stream_id)
            if stream_id in self._seen_headers:
                return
            self._seen_headers.add(stream_id)
            method: Optional[bytes] = None
            path: Optional[bytes] = None
            protocol: Optional[bytes] = None
            for header in event.headers:
                name = header[0]
                if name == b":method":
                    method = header[1]
                elif name == b":path":
                    path = header[1]
                elif name == b":protocol":
                    protocol = header[1]

            if method == b"CONNECT" and protocol == b"webtransport" and path == b"/query":
                if event.stream_ended:
                    self._http.send_headers(
                        stream_id=stream_id,
                        headers=[(b":status", b"400")],
                        end_stream=True,
                    )
                    self.transmit()
                    return
                state.counters["webtransport_connects"] += 1
                self._webtransport_sessions.add(stream_id)
                self._http.send_headers(
                    stream_id=stream_id,
                    headers=[
                        (b":status", b"200"),
                        (b"sec-webtransport-http3-draft", b"draft02"),
                        (b"access-control-allow-origin", b"*"),
                    ],
                )
                self.transmit()
                return

            self._http.send_headers(
                stream_id=stream_id,
                headers=[(b":status", b"404")],
                end_stream=True,
            )
            self.transmit()

        def _datagram_received(self, event: Any) -> None:
            stream_id = int(event.stream_id)
            if stream_id not in self._webtransport_sessions:
                return
            if event.data != WT_DATAGRAM:
                return
            self._http.send_datagram(stream_id=stream_id, data=WT_DATAGRAM_ECHO)
            state.counters["webtransport_echoes"] += 1
            self.transmit()

    FixtureProtocol.__name__ = "FixtureProtocol"
    return FixtureProtocol


def _emit_json(value: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(value, ensure_ascii=True, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def _reject_duplicate_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise InvalidControl()
        result[key] = value
    return result


def _reject_json_constant(_: str) -> Any:
    raise InvalidControl()


def _parse_control(raw: bytes) -> tuple[str, str]:
    if len(raw) > MAX_CONTROL_LINE or not raw.endswith(b"\n"):
        raise InvalidControl()
    try:
        text = raw[:-1].decode("utf-8", errors="strict")
        value = json.loads(
            text,
            object_pairs_hook=_reject_duplicate_pairs,
            parse_constant=_reject_json_constant,
        )
    except Exception as exc:
        raise InvalidControl() from exc
    if not isinstance(value, dict) or set(value) != {"command", "id"}:
        raise InvalidControl()
    command = value["command"]
    command_id = value["id"]
    if command not in ("snapshot", "reset", "stop"):
        raise InvalidControl()
    if not isinstance(command_id, str) or not command_id or len(command_id) > 128:
        raise InvalidControl()
    return command, command_id


def _start_control_reader(loop: asyncio.AbstractEventLoop, queue: asyncio.Queue[Any]) -> None:
    def deliver(item: Any) -> None:
        try:
            loop.call_soon_threadsafe(queue.put_nowait, item)
        except RuntimeError:
            pass

    def read_lines() -> None:
        pending = bytearray()
        while True:
            try:
                chunk = os.read(sys.stdin.fileno(), 4096)
            except BaseException as exc:
                deliver(("fault", type(exc).__name__))
                return
            if not chunk:
                if pending:
                    deliver(("invalid", None))
                else:
                    deliver(("eof", None))
                return

            pending.extend(chunk)
            while True:
                line_end = pending.find(b"\n")
                if line_end < 0:
                    if len(pending) > MAX_CONTROL_LINE:
                        deliver(("invalid", None))
                        return
                    break
                line_size = line_end + 1
                if line_size > MAX_CONTROL_LINE:
                    deliver(("invalid", None))
                    return
                raw = bytes(pending[:line_size])
                del pending[:line_size]
                deliver(("line", raw))
    threading.Thread(target=read_lines, name="fixture-control-reader", daemon=True).start()


def _is_expected_tls_peer_reset(
    context: dict[str, Any], https_protocol_type: type
) -> bool:
    exc = context.get("exception")
    if type(exc) is not ConnectionResetError:
        return False
    if type(context.get("protocol")) is https_protocol_type:
        return True
    for field in ("protocol", "transport"):
        candidate = context.get(field)
        candidate_type = type(candidate)
        if (
            candidate_type.__module__ == "asyncio.sslproto"
            and candidate_type.__name__ in ("SSLProtocol", "_SSLProtocolTransport")
        ):
            return True
    return False


def _handle_loop_exception(
    state: FixtureState,
    https_protocol_type: type,
    _loop: asyncio.AbstractEventLoop,
    context: dict[str, Any],
) -> None:
    if _is_expected_tls_peer_reset(context, https_protocol_type):
        return
    shape = []
    for field in ("protocol", "transport", "future", "handle"):
        candidate = context.get(field)
        candidate_type = type(candidate)
        shape.append(field + "=" + candidate_type.__module__ + "." + candidate_type.__name__)
    handle = context.get("handle")
    callback = getattr(handle, "_callback", None)
    owner = getattr(callback, "__self__", None)
    shape.append("callback_owner=" + type(owner).__module__ + "." + type(owner).__name__)
    protocol = getattr(owner, "_protocol", None)
    shape.append("owner_protocol=" + type(protocol).__module__ + "." + type(protocol).__name__)
    state.fault_contexts.add("loop:" + ";".join(shape))
    exc = context.get("exception")
    if isinstance(exc, BaseException):
        state.record_fault(exc)
    else:
        state.record_fault_type("Exception")


async def _close_servers(tcp_server: Any, quic_server: Any, state: FixtureState) -> None:
    if quic_server is not None:
        try:
            quic_server.close()
        except Exception as exc:
            state.record_fault(exc)
    if tcp_server is not None:
        try:
            tcp_server.close()
            await asyncio.wait_for(tcp_server.wait_closed(), timeout=2.0)
        except Exception as exc:
            state.record_fault(exc)
    for writer in tuple(state.writers):
        try:
            writer.close()
        except Exception as exc:
            state.record_fault(exc)
    if state.https_tasks:
        try:
            done, pending = await asyncio.wait(tuple(state.https_tasks), timeout=2.0)
            for task in pending:
                task.cancel()
            if pending:
                await asyncio.gather(*pending, return_exceptions=True)
        except Exception as exc:
            state.record_fault(exc)
    await asyncio.sleep(0)


def _parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    class SilentArgumentParser(argparse.ArgumentParser):
        def error(self, _message: str) -> None:
            raise InvalidArguments()

    parser = SilentArgumentParser(add_help=False)
    parser.add_argument("--runtime-root", required=True)
    parser.add_argument("--deps-root", required=True)
    try:
        return parser.parse_args(argv)
    except SystemExit as exc:
        raise InvalidArguments() from exc


def main(argv: Optional[list[str]] = None) -> int:
    logging.disable(logging.CRITICAL)
    args: Optional[argparse.Namespace] = None
    try:
        args = _parse_args(argv)
        runtime_root, deps_root = _validate_roots(args.runtime_root, args.deps_root)
        sys.path.insert(0, str(deps_root))

        ssl_context, quic_configuration, fingerprint_b64, fingerprint_hex = _load_tls_material(runtime_root)

        async def run() -> int:
            # Pass the already loaded TLS contexts through a closure so the temporary
            # certificate material is deleted before either socket starts listening.
            from aioquic.asyncio import QuicConnectionProtocol
            from aioquic.asyncio.server import QuicServer
            from aioquic.h3.connection import H3_ALPN, H3Connection
            from aioquic.h3.events import DatagramReceived, HeadersReceived
            from aioquic.quic.events import ProtocolNegotiated

            state = FixtureState()
            loop = asyncio.get_running_loop()
            h3_types = {
                "QuicConnectionProtocol": QuicConnectionProtocol,
                "H3_ALPN": H3_ALPN,
                "H3Connection": H3Connection,
                "HeadersReceived": HeadersReceived,
                "DatagramReceived": DatagramReceived,
                "ProtocolNegotiated": ProtocolNegotiated,
            }
            https_protocol_type = _make_https_protocol_type(state, loop)
            loop.set_exception_handler(
                lambda current_loop, context: _handle_loop_exception(
                    state, https_protocol_type, current_loop, context
                )
            )
            protocol_type = _make_h3_protocol_type(state, h3_types)

            class CountingQuicServer(QuicServer):
                def datagram_received(self, data: bytes, addr: Any) -> None:
                    state.counters["quic_udp_datagrams"] += 1
                    try:
                        super().datagram_received(data, addr)
                    except Exception as exc:
                        state.record_fault(exc)

            tcp_server = None
            quic_server = None
            stop_id: Optional[str] = None
            exit_code = 0
            try:
                last_error: Optional[BaseException] = None
                for _ in range(8):
                    candidate_server = await loop.create_server(
                        https_protocol_type,
                        host="127.0.0.1",
                        port=0,
                        ssl=ssl_context,
                        family=socket.AF_INET,
                    )
                    candidate_port = int(candidate_server.sockets[0].getsockname()[1])
                    try:
                        _, candidate_quic = await loop.create_datagram_endpoint(
                            lambda: CountingQuicServer(
                                configuration=quic_configuration,
                                create_protocol=protocol_type,
                                retry=False,
                            ),
                            local_addr=("127.0.0.1", candidate_port),
                            family=socket.AF_INET,
                        )
                    except OSError as exc:
                        last_error = exc
                        candidate_server.close()
                        await candidate_server.wait_closed()
                        continue
                    except BaseException:
                        candidate_server.close()
                        await candidate_server.wait_closed()
                        raise
                    tcp_server = candidate_server
                    quic_server = candidate_quic
                    port = candidate_port
                    break
                else:
                    port = 0
                if tcp_server is None or quic_server is None:
                    if last_error is not None:
                        raise OSError() from last_error
                    raise OSError()

                _emit_json(
                    {
                        "event": "ready",
                        "fixture_version": FIXTURE_VERSION,
                        "port": port,
                        "url": "https://127.0.0.1:" + str(port) + "/query",
                        "certificate_sha256_base64": fingerprint_b64,
                        "certificate_sha256_hex": fingerprint_hex,
                    }
                )

                control_queue: asyncio.Queue[Any] = asyncio.Queue()
                _start_control_reader(loop, control_queue)
                while True:
                    kind, payload = await control_queue.get()
                    if kind == "eof":
                        break
                    if kind == "fault":
                        state.record_fault_type(str(payload))
                        _emit_json({"event": "fault", "fault_types": sorted(state.fault_types)})
                        exit_code = 2
                        break
                    if kind != "line":
                        state.record_fault_type("InvalidControl")
                        _emit_json({"event": "fault", "fault_types": sorted(state.fault_types)})
                        exit_code = 2
                        break
                    try:
                        command, command_id = _parse_control(payload)
                    except InvalidControl:
                        state.record_fault_type("InvalidControl")
                        _emit_json({"event": "fault", "fault_types": sorted(state.fault_types)})
                        exit_code = 2
                        break

                    if command == "snapshot":
                        _emit_json(
                            {
                                "event": "command",
                                "id": command_id,
                                "counters": state.snapshot(),
                                "fault_types": sorted(state.fault_types),
                                "fault_contexts": sorted(state.fault_contexts),
                            }
                        )
                    elif command == "reset":
                        state.reset()
                        _emit_json(
                            {
                                "event": "command",
                                "id": command_id,
                                "counters": state.snapshot(),
                                "fault_types": sorted(state.fault_types),
                                "fault_contexts": sorted(state.fault_contexts),
                            }
                        )
                    else:
                        stop_id = command_id
                        break
            finally:
                if tcp_server is not None or quic_server is not None:
                    await _close_servers(tcp_server, quic_server, state)
            if stop_id is not None:
                _emit_json(
                    {
                        "event": "stop",
                        "id": stop_id,
                        "stopped": True,
                        "fault_types": sorted(state.fault_types),
                        "fault_contexts": sorted(state.fault_contexts),
                    }
                )
            if exit_code == 0 and state.fault_types:
                exit_code = 1
            return exit_code

        # This socket-only fixture does not need Proactor pipe/subprocess I/O.
        # Python 3.10's Windows Proactor SSL transport callback can raise a
        # ConnectionResetError while closing an aborted TLS peer. Use the
        # standard Selector loop instead of hiding that callback's failures.
        if sys.platform == "win32":
            asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
        return asyncio.run(run())
    except (InvalidArguments, InvalidRuntimeRoot, InvalidDepsRoot) as exc:
        _emit_json({"event": "fault", "fault_types": [type(exc).__name__]})
        return 2
    except BaseException as exc:
        if isinstance(exc, KeyboardInterrupt):
            return 130
        _emit_json({"event": "fault", "fault_types": [type(exc).__name__]})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
