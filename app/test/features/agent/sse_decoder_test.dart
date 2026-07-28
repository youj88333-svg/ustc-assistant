import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ustc_assistant_app/features/agent/data/sse_decoder.dart';

void main() {
  group('SseDecoder', () {
    test('parses a full event sequence delivered as one chunk', () {
      final bytes = utf8.encode(_fullSequence);
      final decoder = SseDecoder();
      final events = decoder.feed(bytes);
      expect(events, isNotEmpty);
      // The sequence ends with message_stop and an error event after a blank
      // line. We expect at least the four typed events.
      final types = events.map((e) => e.event).toList();
      expect(types, contains('message_start'));
      expect(types, contains('content_block_start'));
      expect(types, contains('content_block_delta'));
      expect(types, contains('content_block_stop'));
      expect(types, contains('message_delta'));
      expect(types, contains('message_stop'));
      expect(types, contains('error'));
    });

    test('reassembles multiline data: fields with newline joins', () {
      final source =
          'event: message_start\n'
          'data: {"type":"message_start"}\n'
          'data: {"extra":"line2"}\n'
          '\n';
      final decoder = SseDecoder();
      final events = decoder.feed(utf8.encode(source));
      expect(events, hasLength(1));
      expect(events.single.event, 'message_start');
      expect(events.single.data, '{"type":"message_start"}\n{"extra":"line2"}');
    });

    test('delivers separate events across blank-line delimiters', () {
      final source =
          'event: one\n'
          'data: {"a":1}\n'
          '\n'
          'event: two\n'
          'data: {"b":2}\n'
          '\n';
      final decoder = SseDecoder();
      final events = decoder.feed(utf8.encode(source));
      expect(events.map((e) => e.event), ['one', 'two']);
      expect(events.map((e) => e.data), ['{"a":1}', '{"b":2}']);
    });

    test('buffers a partial UTF-8 multi-byte sequence split across chunks', () {
      // The emoji 🚀 is 4 bytes in UTF-8: F0 9F 9A 80. Split it so the first
      // chunk ends mid-character; the decoder must not emit a replacement
      // char and must reassemble once the remainder arrives.
      const full =
          'event: text\n'
          'data: {"v":"🚀 ok"}\n'
          '\n';
      final all = utf8.encode(full);
      // Find the index of the emoji bytes.
      final emojiBytes = utf8.encode('🚀');
      final emojiStart = _indexOfSublist(all, emojiBytes);
      // Split inside the emoji (one byte in, two bytes remaining).
      final splitAt = emojiStart + 1;
      final first = all.sublist(0, splitAt);
      final second = all.sublist(splitAt);

      final decoder = SseDecoder();
      final firstEvents = decoder.feed(first);
      expect(
        firstEvents,
        isEmpty,
        reason: 'no complete event before the emoji completes',
      );
      final secondEvents = decoder.feed(second);
      expect(secondEvents, hasLength(1));
      expect(secondEvents.single.event, 'text');
      expect(secondEvents.single.data, '{"v":"🚀 ok"}');
    });

    test('handles a split mid-event (field line split across chunks)', () {
      const part1 =
          'event: content_block_delta\n'
          'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hel';
      const part2 = 'lo"}}\n\n';
      final decoder = SseDecoder();
      expect(decoder.feed(utf8.encode(part1)), isEmpty);
      final events = decoder.feed(utf8.encode(part2));
      expect(events, hasLength(1));
      expect(events.single.event, 'content_block_delta');
      expect(
        events.single.data,
        '{"type":"content_block_delta","delta":{"type":"text_delta","text":"hello"}}',
      );
    });

    test(
      'flushes a trailing buffered event without a final blank line on close',
      () {
        const source =
            'event: tail\n'
            'data: {"end":true}';
        final decoder = SseDecoder();
        expect(decoder.feed(utf8.encode(source)), isEmpty);
        final flushed = decoder.close();
        expect(flushed, hasLength(1));
        expect(flushed.single.event, 'tail');
        expect(flushed.single.data, '{"end":true}');
      },
    );

    test('ignores comment lines starting with a colon', () {
      const source =
          ': this is a comment keep-alive\n'
          'event: ping\n'
          'data: {}\n'
          '\n';
      final decoder = SseDecoder();
      final events = decoder.feed(utf8.encode(source));
      expect(events, hasLength(1));
      expect(events.single.event, 'ping');
      expect(events.single.data, '{}');
    });

    test('treats [DONE] sentinel as a terminal data marker', () {
      const source =
          'event: message_stop\n'
          'data: [DONE]\n'
          '\n';
      final decoder = SseDecoder();
      final events = decoder.feed(utf8.encode(source));
      expect(events, hasLength(1));
      expect(events.single.event, 'message_stop');
      expect(events.single.data, '[DONE]');
    });

    test('parses the brief full sequence and yields events in order', () {
      final decoder = SseDecoder();
      final events = decoder.feed(utf8.encode(_fullSequence));
      // Order assertion: message_start precedes content_block_start, etc.
      final order = events.map((e) => e.event).toList();
      expect(
        order.indexOf('message_start'),
        lessThan(order.indexOf('content_block_start')),
      );
      expect(
        order.indexOf('content_block_delta'),
        lessThan(order.indexOf('content_block_stop')),
      );
      expect(
        order.indexOf('message_delta'),
        lessThan(order.indexOf('message_stop')),
      );
    });
  });
}

int _indexOfSublist(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  throw StateError('needle not found');
}

const _fullSequence = '''event: message_start
data: {"type":"message_start","message":{"id":"msg_1","model":"deepseek-v4-flash"}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tool_1","name":"get_weather","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"city\\":"}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\"Hefei\\"}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":1}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"input_tokens":12,"output_tokens":8}}

event: message_stop
data: {"type":"message_stop"}

event: error
data: {"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}

''';
