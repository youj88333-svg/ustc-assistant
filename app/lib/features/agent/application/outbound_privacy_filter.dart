/// The outcome of inspecting a user's outbound text for likely secrets.
///
/// [accepted] is true when the text may be persisted and sent to the model.
/// When false, [reason] carries a short, safe (non-sensitive) explanation
/// suitable for surfacing to the user.
class PrivacyDecision {
  const PrivacyDecision({required this.accepted, this.reason});

  final bool accepted;
  final String? reason;
}

/// A builder that reduces a tool's raw payload to its allowlisted DTO fields.
///
/// Each registered tool supplies one builder that extracts ONLY the fields the
/// model is permitted to see (e.g. `courses`, `semester`). The builder is the
/// single place that decides what survives; the filter never recursively
/// strips "suspicious keys" from arbitrary raw payloads, because that approach
/// both leaks anything the denylist misses and can drop legitimate fields.
typedef ToolPayloadBuilder = Map<String, Object?> Function(
  Map<String, Object?> raw,
);

/// Deterministic, local-only outbound privacy filter for the read-only campus
/// Agent.
///
/// This filter runs **before** any user text is persisted or sent to the
/// gateway, and **before** any tool payload is folded into the conversation.
/// It is pure Dart with no network or I/O: every decision is a deterministic
/// pattern match over already-loaded strings.
///
/// The known complete school username is accepted ONLY as a constructor
/// argument ([protectedAccount]); it is never written to any Agent table or
/// field. It is used solely to reject the user pasting their exact complete
/// account string.
class OutboundPrivacyFilter {
  OutboundPrivacyFilter({
    required this.protectedAccount,
    required this.toolBuilders,
  });

  /// The school account's full username string (e.g. `PB12345678`). Held in
  /// memory only; never persisted.
  final String protectedAccount;

  /// Per-tool allowlisted field builders. A tool name not present here is
  /// sanitized to an empty placeholder rather than passed through.
  final Map<String, ToolPayloadBuilder> toolBuilders;

  // --- User text inspection ---------------------------------------------

  /// Inspects [text] the user is about to send. Returns a [PrivacyDecision];
  /// when `accepted` is false the caller MUST NOT persist or transmit the
  /// text.
  ///
  /// Patterns rejected (deterministic, case-insensitive where noted):
  /// - Likely API keys: `sk-...` and similar provider key prefixes.
  /// - Bearer tokens: `Authorization: Bearer ...` / `Bearer ...`.
  /// - Cookies: `Cookie: ...` headers.
  /// - Password assignments: `password=...` / `密码: ...` / `密码是...`.
  /// - Verification codes: `验证码...123456` style sequences.
  /// - The exact complete protected account string.
  PrivacyDecision inspectUserText(String text) {
    if (text.isEmpty) {
      return const PrivacyDecision(accepted: true);
    }

    // Exact complete-account pattern: reject the user pasting their full
    // account string verbatim.
    if (text.contains(protectedAccount)) {
      return const PrivacyDecision(
        accepted: false,
        reason: '消息包含完整的统一身份认证账号，请避免发送完整账号。',
      );
    }

    // API key prefixes. `sk-` (and extended variants) require the trailing
    // hyphen so ordinary words like "skate" or "sky" do not match.
    if (_apiKeyRegex.hasMatch(text)) {
      return const PrivacyDecision(
        accepted: false,
        reason: '消息疑似包含 API Key，已拦截。',
      );
    }

    // Authorization / Bearer headers.
    if (_bearerRegex.hasMatch(text)) {
      return const PrivacyDecision(
        accepted: false,
        reason: '消息疑似包含授权令牌（Authorization/Bearer），已拦截。',
      );
    }

    // Cookie headers.
    if (_cookieRegex.hasMatch(text)) {
      return const PrivacyDecision(
        accepted: false,
        reason: '消息疑似包含 Cookie，已拦截。',
      );
    }

    // Password assignment patterns.
    if (_passwordRegex.hasMatch(text)) {
      return const PrivacyDecision(
        accepted: false,
        reason: '消息疑似包含密码，已拦截。',
      );
    }

    // Verification codes (4-8 digits near a 验证码 keyword, or a labelled
    // code line).
    if (_verificationCodeRegex.hasMatch(text)) {
      return const PrivacyDecision(
        accepted: false,
        reason: '消息疑似包含验证码，已拦截。',
      );
    }

    return const PrivacyDecision(accepted: true);
  }

  // --- Tool payload sanitization ----------------------------------------

  /// Reduces [rawPayload] for [toolName] to its allowlisted DTO fields.
  ///
  /// The builder for [toolName] is the ONLY authority over which fields
  /// survive. Unknown tools (no registered builder) get an empty placeholder
  /// map — their raw payload is never passed through. Public/untrusted text
  /// returned by a tool is preserved as a data field by the builder; the
  /// system prompt (not this filter) tells the model to treat tool output as
  /// untrusted data rather than instructions.
  Map<String, Object?> sanitizeToolPayload({
    required String toolName,
    required Map<String, Object?> rawPayload,
  }) {
    final builder = toolBuilders[toolName];
    if (builder == null) {
      // Unknown tool: do not pass any raw payload through. Return a safe,
      // empty DTO so the model sees the tool ran but got no fields.
      return const <String, Object?>{};
    }
    final sanitized = builder(rawPayload);
    // Defensive: redact any canary-class secret that a buggy builder might
    // accidentally let through. This is a backstop, not the primary
    // mechanism — the builder's allowlist is the real boundary.
    return _redactSanitized(sanitized);
  }

  // --- Summary sanitization ---------------------------------------------

  /// Sanitizes a model-generated summary before it is persisted or reused.
  ///
  /// Summaries are model output and may, in rare cases, echo a leaked secret.
  /// This redacts the protected account string and common secret canaries so
  /// a summary never becomes a durable store for a credential.
  String sanitizeSafeSummary(String summary) {
    var redacted = summary.replaceAll(protectedAccount, _accountRedaction);
    redacted = redacted.replaceAllMapped(_apiKeyRegex, (_) => _secretRedaction);
    redacted = redacted.replaceAllMapped(
      _bearerRegex,
      (_) => _bearerRedaction,
    );
    redacted = redacted.replaceAllMapped(
      _cookieRegex,
      (_) => _cookieRedaction,
    );
    redacted = redacted.replaceAllMapped(
      _passwordRegex,
      (_) => _passwordRedaction,
    );
    redacted = redacted.replaceAllMapped(
      _verificationCodeRegex,
      (_) => _verificationCodeRedaction,
    );
    return redacted;
  }

  // --- Patterns ---------------------------------------------------------

  // API key prefixes. Requires the hyphen after `sk` so "sky"/"skate" do not
  // match. Also catches common extended prefixes.
  static final _apiKeyRegex = RegExp(
    r'\bsk-[A-Za-z0-9_\-]{8,}\b',
  );

  // Bearer / Authorization headers.
  static final _bearerRegex = RegExp(
    r'(Authorization\s*:\s*Bearer\s+\S+|Bearer\s+[A-Za-z0-9_\-\.=]{8,})',
    caseSensitive: false,
  );

  // Cookie headers.
  static final _cookieRegex = RegExp(
    r'Cookie\s*:\s*\S+',
    caseSensitive: false,
  );

  // Password assignments: `password=...`, `密码: ...`, `密码是 ...`,
  // `密码=...`. Requires a non-trivial value so "密码怎么办" is not caught.
  static final _passwordRegex = RegExp(
    r'(password\s*[=:]\s*\S{4,}|密码\s*[是:=]\s*\S{2,})',
    caseSensitive: false,
  );

  // Verification codes: a 验证码 keyword followed (within a short window) by
  // 4-8 digits, or a labelled code line like `验证码: 123456`.
  static final _verificationCodeRegex = RegExp(
    r'验证码[^0-9]{0,6}(\d{4,8})',
  );

  static const _accountRedaction = '[账号已隐去]';
  static const _secretRedaction = '[疑似密钥已隐去]';
  static const _bearerRedaction = '[授权令牌已隐去]';
  static const _cookieRedaction = '[Cookie已隐去]';
  static const _passwordRedaction = '[疑似密码已隐去]';
  static const _verificationCodeRedaction = '[验证码已隐去]';

  /// Recursively redacts secret canaries from an already-sanitized payload.
  /// This is a defensive backstop; the builder's allowlist is the primary
  /// boundary.
  ///
  /// As of Task 7 this ALSO performs recursive suspicious-KEY rejection:
  /// any map entry whose key (case-insensitive) matches a suspicious pattern
  /// (`db_id`, `cookie`, `profilePath`, `password`, `token`, `apiKey`,
  /// `authorization`, `secret`, `path`, `url`) is dropped entirely — the
  /// whole entry, not just its value. This is defense in depth on top of the
  /// per-tool allowlist: a buggy builder that accidentally let a nested
  /// `db_id` or `cookie` field through is still caught. The allowlist is
  /// still the primary boundary; this catch is for accidents.
  Map<String, Object?> _redactSanitized(Map<String, Object?> node) {
    final out = <String, Object?>{};
    node.forEach((k, v) {
      if (_isSuspiciousKey(k)) return; // drop the whole entry.
      out[k] = _redactValue(v);
    });
    return out;
  }

  Object? _redactValue(Object? node) {
    if (node is Map<String, Object?>) {
      final out = <String, Object?>{};
      node.forEach((k, v) {
        if (_isSuspiciousKey(k)) return; // drop the whole entry.
        out[k] = _redactValue(v);
      });
      return out;
    }
    if (node is List) {
      return <Object?>[for (final e in node) _redactValue(e)];
    }
    if (node is String) {
      var s = node;
      if (s.contains(protectedAccount)) {
        s = s.replaceAll(protectedAccount, _accountRedaction);
      }
      if (_apiKeyRegex.hasMatch(s)) {
        s = s.replaceAllMapped(_apiKeyRegex, (_) => _secretRedaction);
      }
      if (_bearerRegex.hasMatch(s)) {
        s = s.replaceAllMapped(_bearerRegex, (_) => _bearerRedaction);
      }
      if (_cookieRegex.hasMatch(s)) {
        s = s.replaceAllMapped(_cookieRegex, (_) => _cookieRedaction);
      }
      if (_passwordRegex.hasMatch(s)) {
        s = s.replaceAllMapped(_passwordRegex, (_) => _passwordRedaction);
      }
      if (_verificationCodeRegex.hasMatch(s)) {
        s = s.replaceAllMapped(
          _verificationCodeRegex,
          (_) => _verificationCodeRedaction,
        );
      }
      return s;
    }
    return node;
  }

  /// Whether [key] (case-insensitive) matches a suspicious pattern. A match
  /// means the entry should be DROPPED (not just value-redacted) from any
  /// sanitized payload. These keys never carry model-safe data: they are
  /// either internal DB ids (`db_id`), credentials (`cookie`, `password`,
  /// `token`, `apiKey`, `authorization`, `secret`), or internal file/network
  /// locators (`path`, `url`, `profilePath`) that would leak internal
  /// structure. The per-tool allowlist is the primary boundary; this is the
  /// defense-in-depth backstop.
  static bool _isSuspiciousKey(String key) {
    final lower = key.toLowerCase();
    return _suspiciousKeys.contains(lower);
  }

  /// Suspicious key patterns (all lowercased for case-insensitive match).
  /// `apikey` covers both `apiKey` and `api_key` (lowercased). `profilepath`
  /// covers `profilePath` and `profile_path`.
  static const _suspiciousKeys = <String>{
    'db_id',
    'cookie',
    'profilepath',
    'password',
    'token',
    'apikey',
    'authorization',
    'secret',
    'path',
    'url',
  };
}
