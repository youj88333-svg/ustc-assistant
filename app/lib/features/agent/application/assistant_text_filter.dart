/// Incrementally sanitizes streamed assistant text as SSE deltas arrive.
///
/// Two classes of leakage are removed WITHOUT waiting for the stream to end
/// (a final regex-only pass would let them flash in the UI transiently):
///
/// 1. **Leading history timestamps** — the model sometimes opens an assistant
///    turn with a history marker like `[2026-08-01T19:42]`. These are stripped
///    only at the very START of an assistant turn (one or more). Body-internal
///    timestamps such as `正文时间 [2026-08-01T19:42]` are legitimate content
///    and are preserved.
///
/// 2. **`ref_*` leakage** — run-local opaque reference tokens (`ref_...`) are
///    internal, never meant for the user. A complete `ref_` token is replaced
///    with the safe placeholder [refPlaceholder]. A SPLIT token (crossing a
///    delta boundary) is held back until its full extent is determined so the
///    raw token never appears even transiently. An INCOMPLETE `ref_` prefix at
///    stream end is dropped entirely — never persisted.
///
/// Carry is bounded: at most one trailing `ref_` token (plus its leading
/// whitespace) or one partial leading marker is ever held between calls.
class AssistantTextFilter {
  /// The safe placeholder replacing a `ref_*` token in user-visible text.
  static const String refPlaceholder = '该条目';

  /// Hard cap on the carried tail (an incomplete `ref_` prefix or partial
  /// leading marker). Real ref tokens from [RunReferenceStore] are ~22 chars,
  /// so 256 is far beyond any legitimate hold; if a pathologically long stream
  /// ever exceeds it, the overflow is force-decided (replaced safely) rather
  /// than held, keeping memory bounded.
  static const int maxCarry = 256;

  /// A complete leading history-marker: `[YYYY-MM-DDTHH:MM]` (optionally with
  /// fractional seconds), followed by any trailing whitespace.
  static final RegExp _markerRe =
      RegExp(r'^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{2,8}([.:][0-9]+)?\]\s*');

  /// A trailing decidable `ref_` token prefix (may be incomplete).
  static final RegExp _refPrefixRe = RegExp(r'^ref_[A-Za-z0-9_-]*$');

  /// One complete `ref_...` token including any leading whitespace.
  static final RegExp _refTokenRe = RegExp(r'\s*ref_[A-Za-z0-9_-]*');

  final StringBuffer _buffer = StringBuffer();

  /// True until the first decidable (non-marker) content is found. While true,
  /// leading history timestamps are still being suppressed.
  bool _markerOpen = true;

  /// Appends a streamed [delta] and returns the portion now safe to display.
  /// Output may be empty while the filter holds an incomplete token.
  String add(String delta) {
    _buffer.write(delta);
    return _process(isFinal: false);
  }

  /// Ends the turn: emits any decidable trailing content and drops an
  /// incomplete leading marker or trailing `ref_` prefix (never persisted).
  String finish() {
    return _process(isFinal: true);
  }

  /// Drops any held carry and re-opens the leading-marker stripping zone.
  ///
  /// Called when a tool-use turn's streamed text is discarded (restored to the
  /// pre-turn visible draft): the partial carry from that discarded turn must
  /// not bleed into the next turn, and the next assistant turn is allowed to
  /// strip fresh leading history markers.
  void reset() {
    _buffer.clear();
    _markerOpen = true;
  }

  String _process({required bool isFinal}) {
    var text = _buffer.toString();
    _buffer.clear();
    if (text.isEmpty) return '';

    final out = StringBuffer();

    // --- 1. Suppress leading history markers (only while the zone is open). --
    if (_markerOpen) {
      var exhaustedMarkers = false;
      while (text.startsWith('[')) {
        if (text.length == 1) {
          // A lone "[" — could be the start of a marker. Hold (or drop at end).
          if (isFinal) {
            _markerOpen = false;
            text = '';
          } else {
            _buffer.write(text);
            return out.toString();
          }
          exhaustedMarkers = true;
          break;
        }
        final m = _markerRe.matchAsPrefix(text);
        if (m != null) {
          // A complete marker (plus trailing whitespace) — remove it.
          text = text.substring(m.end);
          continue;
        }
        if (!_isDigit(text[1])) {
          // Starts with '[' followed by a non-digit -> not a marker; content
          // begins here. Close the zone.
          _markerOpen = false;
          exhaustedMarkers = true;
          break;
        }
        // Starts with '[' + digit. If a closing ']' is already present but the
        // full marker regex did NOT match, this cannot be a timestamp marker —
        // it is legal content like "[2] 正文" or "[2025年度]". Close the zone
        // and emit it as content rather than silently holding (and later
        // dropping) it.
        if (text.contains(']')) {
          _markerOpen = false;
          exhaustedMarkers = true;
          break;
        }
        // No closing ']' yet -> possibly an incomplete marker still streaming.
        // Hold (or drop at stream end if it turns out incomplete).
        if (isFinal) {
          // Drop the incomplete leading marker entirely.
          _markerOpen = false;
          text = '';
          exhaustedMarkers = true;
          break;
        }
        _buffer.write(text);
        return out.toString();
      }
      if (!exhaustedMarkers && text.startsWith('[')) {
        // We exited the while loop without consuming a marker — not possible.
        exhaustedMarkers = true;
      }
      if (text.isEmpty) {
        // Pure markers consumed; nothing decidable yet. Keep searching for
        // any further leading markers on the next delta, but if this is the
        // end there is nothing to emit.
        if (isFinal) return out.toString();
        return out.toString();
      }
      // text now begins with real content (or we closed the zone because the
      // first char was non-'['). Zone is closed.
      _markerOpen = false;
    }

    // --- 2. Ref-token sanitization -----------------------------------------
    if (text.isEmpty) return out.toString();

    var (safeText, heldTail) = _partitionRef(text);
    // Bounded carry: never hold more than maxCarry chars. If the held tail
    // grows past the cap, force-decide it safely (the ref token is replaced by
    // the placeholder) so memory stays bounded no matter the stream.
    if (heldTail.length > maxCarry) {
      final head = heldTail;
      heldTail = '';
      safeText = safeText + head;
    }
    if (safeText.isNotEmpty) {
      out.write(_replaceRefs(safeText));
    }
    if (heldTail.isNotEmpty) {
      if (isFinal) {
        // An unterminated trailing `ref_` prefix at stream end is dropped —
        // never persisted, and no placeholder is emitted for an incomplete
        // token. The entire held tail (whitespace + prefix) is discarded.
        // Nothing appended to output.
      } else {
        _buffer
          ..clear()
          ..write(heldTail);
      }
    }
    return out.toString();
  }

  /// Splits [text] into a decidable safe prefix and a held tail that is a
  /// trailing `ref_` prefix (`\s*ref_[A-Za-z0-9_-]*` to the end of [text]).
  (String, String) _partitionRef(String text) {
    final refIndex = text.lastIndexOf('ref_');
    if (refIndex < 0) return (text, '');
    if (!_refPrefixRe.hasMatch(text.substring(refIndex))) {
      return (text, '');
    }
    // Extend the held tail backward over any preceding whitespace so a token
    // split across deltas consumes its leading space together.
    var start = refIndex;
    while (start > 0 && _isWhitespace(text.codeUnitAt(start - 1))) {
      start--;
    }
    return (text.substring(0, start), text.substring(start));
  }

  String _replaceRefs(String text) =>
      text.replaceAllMapped(_refTokenRe, (_) => refPlaceholder);

  static bool _isDigit(String ch) {
    final code = ch.codeUnitAt(0);
    return code >= 0x30 && code <= 0x39;
  }

  static bool _isWhitespace(int code) =>
      code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D;
}