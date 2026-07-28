import 'dart:convert';

/// A single Server-Sent Event: the `event:` type (defaults to `'message'`
/// per the SSE spec when omitted) and the reassembled `data:` string with
/// multiline fields joined by `\n`.
final class SseEvent {
  const SseEvent({required this.event, required this.data});

  final String event;
  final String data;

  @override
  String toString() => 'SseEvent($event, ${data.length} bytes)';
}

/// A stateful Server-Sent Events decoder.
///
/// Feed it raw `List<int>` byte chunks via [feed]; it buffers partial UTF-8
/// byte sequences so a multi-byte character split across chunks is decoded
/// correctly, and buffers partial lines so an event split across chunks is
/// only emitted once its terminating blank line arrives. Call [close] to
/// flush any trailing buffered event that was not followed by a blank line.
///
/// Behaviour:
/// - Lines beginning with `:` are comments (ignored, used for keep-alives).
/// - `event:` sets the event type for the current event.
/// - `data:` appends to the current event's data; multiple `data:` fields
///   are concatenated with `\n` between them (per the SSE spec).
/// - A blank line dispatches the current event and resets the buffer.
/// - The `[DONE]` sentinel is surfaced verbatim as the event's [data]; the
///   caller decides whether to treat it as terminal.
class SseDecoder {
  SseDecoder();

  // Bytes that have not yet formed a complete UTF-8 sequence.
  final List<int> _byteBuffer = [];
  // Decoded text not yet terminated by a newline.
  final StringBuffer _lineBuffer = StringBuffer();
  // The event type accumulated for the current event.
  String _pendingEvent = '';
  // The data lines accumulated for the current event.
  final List<String> _pendingData = [];
  // Whether the current event has seen any field yet (to suppress empty
  // events at the very start of the stream).
  bool _eventStarted = false;

  /// Feed a chunk of raw bytes and return any fully-formed events that
  /// completed as a result. Partial UTF-8 sequences and partial lines are
  /// buffered for the next call.
  List<SseEvent> feed(List<int> chunk) {
    _byteBuffer.addAll(chunk);
    final out = <SseEvent>[];

    // Decode as many complete UTF-8 sequences as we can, leaving any
    // trailing partial sequence in the buffer.
    final decoded = _decodeComplete();
    for (var i = 0; i < decoded.length; i++) {
      final char = decoded[i];
      if (char == '\n') {
        _flushLine(out);
      } else if (char != '\r') {
        // Strip a lone CR so CRLF and LF both terminate lines cleanly.
        _lineBuffer.write(char);
      } else {
        // CR alone: treat as end of line only when not followed by LF (which
        // we handle in the next iteration). To keep this simple and spec-
        // aligned for our gateway (which uses LF), we drop a trailing CR
        // that is not part of CRLF by ignoring it here; the following LF
        // will flush the line.
      }
    }
    return out;
  }

  /// Flush any trailing buffered event. Call once after the last chunk has
  /// been fed. Returns the final buffered event (if any) and resets state.
  List<SseEvent> close() {
    final out = <SseEvent>[];
    // Flush any remaining text as a final line.
    if (_lineBuffer.isNotEmpty) {
      _flushLine(out);
    }
    // Flush a pending event that had fields but no trailing blank line.
    if (_eventStarted) {
      out.add(_emitAndReset());
    }
    return out;
  }

  void _flushLine(List<SseEvent> out) {
    final line = _lineBuffer.toString();
    _lineBuffer.clear();
    // An empty line dispatches the current event.
    if (line.isEmpty) {
      if (_eventStarted) {
        out.add(_emitAndReset());
      }
      return;
    }
    if (line.startsWith(':')) {
      // Comment / keep-alive: ignore.
      _eventStarted = true;
      return;
    }
    final colon = line.indexOf(':');
    String field;
    String value;
    if (colon == -1) {
      field = line;
      value = '';
    } else {
      field = line.substring(0, colon);
      // Per spec, a single leading space after the colon is stripped.
      var valueStart = colon + 1;
      if (valueStart < line.length && line[valueStart] == ' ') {
        valueStart++;
      }
      value = line.substring(valueStart);
    }
    if (field == 'event') {
      _pendingEvent = value;
      _eventStarted = true;
    } else if (field == 'data') {
      _pendingData.add(value);
      _eventStarted = true;
    }
    // Other fields (id, retry) are not used by this gateway; ignore them
    // but mark the event as started so a blank line still dispatches.
    _eventStarted = true;
  }

  SseEvent _emitAndReset() {
    final event = SseEvent(
      event: _pendingEvent.isEmpty ? 'message' : _pendingEvent,
      data: _pendingData.join('\n'),
    );
    _pendingEvent = '';
    _pendingData.clear();
    _eventStarted = false;
    return event;
  }

  /// Decodes as many complete UTF-8 sequences as possible from
  /// [_byteBuffer], leaving any trailing partial sequence buffered. Returns
  /// the decoded string.
  String _decodeComplete() {
    if (_byteBuffer.isEmpty) return '';
    // Use Utf8Decoder with allowMalformed=false and let it report how many
    // bytes it consumed by re-encoding the remainder. The simplest robust
    // approach: find the longest prefix that decodes cleanly by trying
    // progressively shorter prefixes when aFormatException is raised.
    final decoder = const Utf8Decoder();
    // Try the whole buffer first.
    try {
      final s = decoder.convert(_byteBuffer);
      _byteBuffer.clear();
      return s;
    } on FormatException {
      // Fall through to incremental trimming.
    }
    // Find the largest prefix length that decodes without error. We scan
    // backwards from the end, looking for the last safe boundary. A UTF-8
    // lead byte (0x00-0x7F, 0xC0-0xFF) is a safe start point.
    var safeLen = _byteBuffer.length;
    // Trim trailing bytes that could be a partial sequence: any byte whose
    // top bits mark it as a continuation byte (0x80-0xBF) or a lead byte
    // whose announced length exceeds the remaining buffer.
    while (safeLen > 0) {
      final lead = _byteBuffer[safeLen - 1];
      if (lead < 0x80) {
        // ASCII: single byte, safe boundary at safeLen (lead included).
        break;
      }
      // Determine the expected sequence length from the lead byte.
      int expected;
      if ((lead & 0xE0) == 0xC0) {
        expected = 2;
      } else if ((lead & 0xF0) == 0xE0) {
        expected = 3;
      } else if ((lead & 0xF8) == 0xF0) {
        expected = 4;
      } else {
        // Continuation byte (0x80-0xBF) or invalid lead: trim one byte.
        safeLen--;
        continue;
      }
      final remaining = _byteBuffer.length - (safeLen - 1);
      if (remaining >= expected) {
        // The lead byte has all its continuation bytes; this is a safe
        // boundary at safeLen (lead included). But we must still verify the
        // prefix decodes; break to attempt decoding.
        break;
      }
      // Partial multi-byte sequence at the end: trim the lead byte.
      safeLen--;
    }

    if (safeLen <= 0) return '';
    try {
      final s = decoder.convert(_byteBuffer.sublist(0, safeLen));
      // Keep the unconsumed tail.
      final tail = _byteBuffer.sublist(safeLen);
      _byteBuffer.clear();
      _byteBuffer.addAll(tail);
      return s;
    } on FormatException {
      // The trimmed prefix still failed (e.g. an invalid byte in the
      // middle). Drop one byte and retry to make progress.
      final tail = _byteBuffer.sublist(1);
      _byteBuffer.clear();
      _byteBuffer.addAll(tail);
      return _decodeComplete();
    }
  }
}
