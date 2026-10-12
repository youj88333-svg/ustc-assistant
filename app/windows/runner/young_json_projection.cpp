#include "young_json_projection.h"

#include <array>
#include <charconv>
#include <cmath>
#include <new>
#include <stdexcept>
#include <utility>
#include <vector>

namespace young_probe {
namespace {

constexpr size_t kMaximumKeyChars = 256;
constexpr size_t kMaximumIdentifierChars = 128;
constexpr size_t kMaximumNumberChars = 128;
constexpr size_t kMaximumPlatformObjectIdChars = 4096;
constexpr size_t kMaximumBusinessRecords = 10;
constexpr size_t kMaximumInitiatorJsonDepth = 40;

struct Span {
  ValueKind kind = ValueKind::absent;
  size_t begin = 0;
  size_t end = 0;
  bool escaped = false;
};

bool White(wchar_t value) noexcept {
  return value == L' ' || value == L'\t' || value == L'\r' || value == L'\n';
}

bool Digit(wchar_t value) noexcept { return value >= L'0' && value <= L'9'; }

int Hex(wchar_t value) noexcept {
  if (value >= L'0' && value <= L'9') return value - L'0';
  if (value >= L'a' && value <= L'f') return value - L'a' + 10;
  if (value >= L'A' && value <= L'F') return value - L'A' + 10;
  return -1;
}

bool HighSurrogate(unsigned int value) noexcept {
  return value >= 0xd800 && value <= 0xdbff;
}

bool LowSurrogate(unsigned int value) noexcept {
  return value >= 0xdc00 && value <= 0xdfff;
}

bool AsciiLiteral(const wchar_t* raw, const Span& span, const char* literal,
                  bool folded = false) noexcept {
  if (span.kind != ValueKind::string || span.escaped || span.end < span.begin + 2)
    return false;
  const size_t length = span.end - span.begin - 2;
  size_t index = 0;
  for (; literal[index] != '\0'; ++index) {
    if (index >= length) return false;
    wchar_t value = raw[span.begin + 1 + index];
    if (folded && value >= L'A' && value <= L'Z') value += L'a' - L'A';
    if (value != static_cast<unsigned char>(literal[index])) return false;
  }
  return index == length;
}

bool RawLiteral(const wchar_t* raw, const Span& span,
                const char* literal) noexcept {
  size_t index = 0;
  for (; literal[index] != '\0'; ++index) {
    if (span.begin + index >= span.end ||
        raw[span.begin + index] != static_cast<unsigned char>(literal[index]))
      return false;
  }
  return span.begin + index == span.end;
}

bool SameKey(const wchar_t* raw, const Span& left, const Span& right) noexcept {
  if (left.end - left.begin != right.end - right.begin) return false;
  for (size_t offset = 1; offset + 1 < left.end - left.begin; ++offset) {
    if (raw[left.begin + offset] != raw[right.begin + offset]) return false;
  }
  return true;
}

bool SecretKey(const wchar_t* raw, const Span& key) noexcept {
  constexpr const char* forbidden[] = {
      "token", "accesstoken", "refreshtoken", "password", "cookie",
      "session", "authentication"};
  for (const char* name : forbidden) {
    if (AsciiLiteral(raw, key, name, true)) return true;
  }
  return false;
}

// This scanner owns no input and creates no strings or subobject copies.
// Escapes in values are validated structurally; only the two explicit decoders
// below interpret selected identifiers and the response-body protocol string.
class Scanner {
 public:
  Scanner(const wchar_t* raw, size_t length, size_t maximum, bool forbid_secrets,
          Rejection malformed, size_t maximum_depth = kMaximumDepth)
      : raw_(raw), length_(length), maximum_(maximum),
        forbid_secrets_(forbid_secrets), malformed_(malformed),
        maximum_depth_(maximum_depth) {}

  bool Document(Span& result) {
    if (length_ > maximum_) return Fail(Rejection::limit);
    if (!raw_ || length_ == 0) return Fail(malformed_);
    SkipWhite();
    if (!Value(result, 0)) return false;
    SkipWhite();
    return position_ == length_ || Fail(malformed_);
  }

  bool Value(Span& result, size_t depth) {
    if (depth > maximum_depth_ || ++nodes_ > kMaximumNodes)
      return Fail(Rejection::limit);
    SkipWhite();
    if (position_ >= length_) return Fail(malformed_);
    result.begin = position_;
    result.escaped = false;
    switch (raw_[position_]) {
      case L'{':
        if (depth >= maximum_depth_) return Fail(Rejection::limit);
        result.kind = ValueKind::object;
        if (!Object(depth + 1)) return false;
        break;
      case L'[':
        if (depth >= maximum_depth_) return Fail(Rejection::limit);
        result.kind = ValueKind::array;
        if (!Array(depth + 1)) return false;
        break;
      case L'"':
        return String(result, false);
      case L't':
        result.kind = ValueKind::boolean;
        if (!Literal("true")) return false;
        break;
      case L'f':
        result.kind = ValueKind::boolean;
        if (!Literal("false")) return false;
        break;
      case L'n':
        result.kind = ValueKind::null_value;
        if (!Literal("null")) return false;
        break;
      default:
        result.kind = ValueKind::number;
        if (!Number()) return false;
        break;
    }
    result.end = position_;
    return true;
  }

  bool String(Span& result, bool key) {
    if (!Consume(L'"')) return false;
    result.kind = ValueKind::string;
    result.begin = position_ - 1;
    result.escaped = false;
    while (position_ < length_) {
      unsigned int value = static_cast<unsigned int>(raw_[position_++]);
      if (value == L'"') {
        result.end = position_;
        if (key && result.end - result.begin - 2 > kMaximumKeyChars)
          return Fail(Rejection::limit);
        return true;
      }
      if (value < 0x20 || value > 0xffff) return Fail(malformed_);
      if (value == L'\\') {
        result.escaped = true;
        // Reject all escaped keys, including in unselected nested objects.
        if (key) return Fail(malformed_);
        if (position_ >= length_) return Fail(malformed_);
        const wchar_t escape = raw_[position_++];
        if (escape == L'u') {
          unsigned int unicode = 0;
          if (!Unicode(unicode)) return false;
          if (HighSurrogate(unicode)) {
            if (!Consume(L'\\') || !Consume(L'u')) return false;
            unsigned int low = 0;
            if (!Unicode(low) || !LowSurrogate(low)) return Fail(malformed_);
          } else if (LowSurrogate(unicode)) {
            return Fail(malformed_);
          }
        } else if (escape != L'"' && escape != L'\\' && escape != L'/' &&
                   escape != L'b' && escape != L'f' && escape != L'n' &&
                   escape != L'r' && escape != L't') {
          return Fail(malformed_);
        }
      } else if (HighSurrogate(value)) {
        if (position_ >= length_ ||
            !LowSurrogate(static_cast<unsigned int>(raw_[position_++])))
          return Fail(malformed_);
      } else if (LowSurrogate(value)) {
        return Fail(malformed_);
      }
    }
    return Fail(malformed_);
  }

  bool Consume(wchar_t expected) {
    if (position_ >= length_ || raw_[position_] != expected)
      return Fail(malformed_);
    ++position_;
    return true;
  }

  void SkipWhite() noexcept {
    while (position_ < length_ && White(raw_[position_])) ++position_;
  }
  wchar_t Peek() const noexcept {
    return position_ < length_ ? raw_[position_] : L'\0';
  }
  size_t position() const noexcept { return position_; }
  void position(size_t value) noexcept { position_ = value; }
  Rejection rejection() const noexcept { return rejection_; }
  bool Fail(Rejection reason) noexcept {
    if (rejection_ == Rejection::none) rejection_ = reason;
    return false;
  }

 private:
  bool Unicode(unsigned int& value) {
    value = 0;
    for (int digit = 0; digit < 4; ++digit) {
      if (position_ >= length_) return Fail(malformed_);
      const int hex = Hex(raw_[position_++]);
      if (hex < 0) return Fail(malformed_);
      value = value * 16 + static_cast<unsigned int>(hex);
    }
    return true;
  }

  bool Literal(const char* literal) {
    for (size_t index = 0; literal[index] != '\0'; ++index) {
      if (position_ >= length_ ||
          raw_[position_++] != static_cast<unsigned char>(literal[index]))
        return Fail(malformed_);
    }
    return true;
  }

  bool Number() {
    const size_t begin = position_;
    if (Peek() == L'-') ++position_;
    if (Peek() == L'0') {
      ++position_;
      if (Digit(Peek())) return Fail(malformed_);
    } else {
      if (Peek() < L'1' || Peek() > L'9') return Fail(malformed_);
      while (Digit(Peek())) ++position_;
    }
    if (Peek() == L'.') {
      ++position_;
      if (!Digit(Peek())) return Fail(malformed_);
      while (Digit(Peek())) ++position_;
    }
    if (Peek() == L'e' || Peek() == L'E') {
      ++position_;
      if (Peek() == L'+' || Peek() == L'-') ++position_;
      if (!Digit(Peek())) return Fail(malformed_);
      while (Digit(Peek())) ++position_;
    }
    if (position_ - begin > kMaximumNumberChars) return Fail(Rejection::limit);
    return true;
  }

  bool Object(size_t depth) {
    ++position_;
    SkipWhite();
    if (Peek() == L'}') {
      ++position_;
      return true;
    }
    std::array<Span, kMaximumObjectMembers> keys{};
    size_t members = 0;
    while (true) {
      if (members >= keys.size()) return Fail(Rejection::limit);
      Span key;
      if (!String(key, true)) return false;
      for (size_t index = 0; index < members; ++index) {
        if (SameKey(raw_, keys[index], key)) return Fail(malformed_);
      }
      keys[members++] = key;
      if (forbid_secrets_ && SecretKey(raw_, key)) return Fail(Rejection::body);
      SkipWhite();
      if (!Consume(L':')) return false;
      Span ignored;
      if (!Value(ignored, depth)) return false;
      SkipWhite();
      if (Peek() == L'}') {
        ++position_;
        return true;
      }
      if (!Consume(L',')) return false;
      SkipWhite();
    }
  }

  bool Array(size_t depth) {
    ++position_;
    SkipWhite();
    if (Peek() == L']') {
      ++position_;
      return true;
    }
    size_t elements = 0;
    while (true) {
      if (++elements > kMaximumArrayElements) return Fail(Rejection::limit);
      Span ignored;
      if (!Value(ignored, depth)) return false;
      SkipWhite();
      if (Peek() == L']') {
        ++position_;
        return true;
      }
      if (!Consume(L',')) return false;
      SkipWhite();
    }
  }

  const wchar_t* raw_;
  size_t length_;
  size_t maximum_;
  bool forbid_secrets_;
  Rejection malformed_;
  size_t maximum_depth_;
  size_t position_ = 0;
  size_t nodes_ = 0;
  Rejection rejection_ = Rejection::none;
};

struct Document {
  const wchar_t* raw;
  size_t length;
  size_t maximum;
  Rejection malformed;
  size_t depth_limit = kMaximumDepth;
  Span root{};
  Rejection rejection = Rejection::none;

  bool Validate(bool forbid_secrets = false,
                size_t maximum_depth = kMaximumDepth) {
    depth_limit = maximum_depth;
    Scanner scanner(raw, length, maximum, forbid_secrets, malformed,
                    maximum_depth);
    if (scanner.Document(root)) return true;
    rejection = scanner.rejection();
    return false;
  }
};

// The full document has already passed all syntax, duplicate, secret-key and
// resource checks. A bounded second scan selects spans only, without creating
// a tree, allocating key strings, or interpreting any unselected value.
template <size_t N>
bool Fields(const Document& document, const Span& object,
            const std::array<const char*, N>& names, std::array<Span, N>& values,
            size_t* member_count = nullptr) {
  if (object.kind != ValueKind::object) return false;
  Scanner scanner(document.raw, document.length, document.maximum, false,
                  document.malformed, document.depth_limit);
  scanner.position(object.begin);
  if (!scanner.Consume(L'{')) return false;
  scanner.SkipWhite();
  size_t count = 0;
  if (scanner.Peek() == L'}') {
    if (member_count) *member_count = 0;
    return true;
  }
  while (true) {
    if (++count > kMaximumObjectMembers) return false;
    Span key;
    Span value;
    if (!scanner.String(key, true)) return false;
    scanner.SkipWhite();
    if (!scanner.Consume(L':') || !scanner.Value(value, 1)) return false;
    for (size_t index = 0; index < N; ++index) {
      if (AsciiLiteral(document.raw, key, names[index])) values[index] = value;
    }
    scanner.SkipWhite();
    if (scanner.Peek() == L'}') {
      if (member_count) *member_count = count;
      return scanner.position() + 1 == object.end;
    }
    if (!scanner.Consume(L',')) return false;
    scanner.SkipWhite();
  }
}

template <typename T>
ParseResult<T> Reject(Rejection reason) {
  return {std::nullopt, reason};
}

bool IdentifierCharacter(wchar_t value) noexcept {
  return (value >= L'a' && value <= L'z') ||
         (value >= L'A' && value <= L'Z') || Digit(value) || value == L'.' ||
         value == L'-' || value == L'_' || value == L':';
}

bool DecodeIdentifier(const Document& document, const Span& span,
                      std::wstring& result, DecodeAudit* audit) {
  if (span.kind != ValueKind::string) return false;
  if (audit) ++audit->identifier_values;
  std::array<wchar_t, kMaximumIdentifierChars> selected{};
  size_t count = 0;
  for (size_t position = span.begin + 1; position + 1 < span.end;) {
    wchar_t value = document.raw[position++];
    if (value == L'\\') {
      const wchar_t escape = document.raw[position++];
      if (escape != L'u') return false;  // No allowed identifier uses another escape.
      unsigned int unicode = 0;
      for (int digit = 0; digit < 4; ++digit) {
        const int hex = Hex(document.raw[position++]);
        if (hex < 0) return false;  // Validation precedes this decoder.
        unicode = unicode * 16 + static_cast<unsigned int>(hex);
      }
      if (unicode > 0x7f) return false;
      value = static_cast<wchar_t>(unicode);
    }
    if (!IdentifierCharacter(value) || count >= selected.size()) return false;
    selected[count++] = value;
    if (audit) ++audit->identifier_units;
  }
  if (count == 0) return false;
  result.assign(selected.data(), count);
  return true;
}

class WipedString {
 public:
  WipedString() = default;
  WipedString(const WipedString&) = delete;
  WipedString& operator=(const WipedString&) = delete;
  ~WipedString() { SecureErase(value_.data(), value_.size()); }

  std::wstring& value() noexcept { return value_; }

 private:
  std::wstring value_;
};

struct DecodedText {
  std::array<wchar_t, kMaximumPlatformObjectIdChars> value{};
  size_t size = 0;

  ~DecodedText() { SecureErase(value.data(), value.size()); }
  std::wstring_view view() const noexcept { return {value.data(), size}; }
};

bool AppendDecodedUnit(DecodedText& output, wchar_t value, size_t maximum,
                       DecodeAudit* audit, bool business) noexcept {
  if (output.size >= maximum || output.size >= output.value.size()) return false;
  output.value[output.size++] = value;
  if (audit) {
    if (business) ++audit->business_units;
    else ++audit->identifier_units;
  }
  return true;
}

bool DecodeBoundedText(const Document& document, const Span& span,
                       size_t maximum, DecodedText& output,
                       DecodeAudit* audit, bool business) {
  if (span.kind != ValueKind::string || maximum > output.value.size()) return false;
  if (audit) {
    if (business) ++audit->business_values;
    else ++audit->identifier_values;
  }
  for (size_t position = span.begin + 1; position + 1 < span.end;) {
    unsigned int value = static_cast<unsigned int>(document.raw[position++]);
    if (value == L'\\') {
      const wchar_t escape = document.raw[position++];
      switch (escape) {
        case L'"': value = L'"'; break;
        case L'\\': value = L'\\'; break;
        case L'/': value = L'/'; break;
        case L'b': value = L'\b'; break;
        case L'f': value = L'\f'; break;
        case L'n': value = L'\n'; break;
        case L'r': value = L'\r'; break;
        case L't': value = L'\t'; break;
        case L'u': {
          value = 0;
          for (int digit = 0; digit < 4; ++digit) {
            const int hex = Hex(document.raw[position++]);
            if (hex < 0) return false;
            value = value * 16 + static_cast<unsigned int>(hex);
          }
          if (HighSurrogate(value)) {
            if (document.raw[position++] != L'\\' ||
                document.raw[position++] != L'u') return false;
            unsigned int low = 0;
            for (int digit = 0; digit < 4; ++digit) {
              const int hex = Hex(document.raw[position++]);
              if (hex < 0) return false;
              low = low * 16 + static_cast<unsigned int>(hex);
            }
            if (!LowSurrogate(low) ||
                !AppendDecodedUnit(output, static_cast<wchar_t>(value), maximum,
                                   audit, business) ||
                !AppendDecodedUnit(output, static_cast<wchar_t>(low), maximum,
                                   audit, business)) return false;
            continue;
          }
          if (LowSurrogate(value)) return false;
          break;
        }
        default: return false;
      }
      if (!AppendDecodedUnit(output, static_cast<wchar_t>(value), maximum,
                             audit, business)) return false;
      continue;
    }
    if (HighSurrogate(value)) {
      if (position + 1 >= span.end) return false;
      const unsigned int low = static_cast<unsigned int>(document.raw[position++]);
      if (!LowSurrogate(low) ||
          !AppendDecodedUnit(output, static_cast<wchar_t>(value), maximum,
                             audit, business) ||
          !AppendDecodedUnit(output, static_cast<wchar_t>(low), maximum,
                             audit, business)) return false;
      continue;
    }
    if (LowSurrogate(value) ||
        !AppendDecodedUnit(output, static_cast<wchar_t>(value), maximum,
                           audit, business)) return false;
  }
  return true;
}

bool BusinessControl(wchar_t value) noexcept {
  return value <= 0x1f || (value >= 0x7f && value <= 0x9f);
}

bool BusinessWhitespace(unsigned int value) noexcept {
  return value == 0x20 || (value >= 0x09 && value <= 0x0d) || value == 0x85 ||
         value == 0xa0 || value == 0x1680 ||
         (value >= 0x2000 && value <= 0x200a) || value == 0x2028 ||
         value == 0x2029 || value == 0x202f || value == 0x205f ||
         value == 0x3000;
}

bool HasControl(const DecodedText& value) noexcept {
  for (size_t index = 0; index < value.size; ++index) {
    if (BusinessControl(value.value[index])) return true;
  }
  return false;
}

bool HasWhitespace(const DecodedText& value) noexcept {
  for (size_t index = 0; index < value.size; ++index) {
    unsigned int code_point = static_cast<unsigned int>(value.value[index]);
    if (HighSurrogate(code_point) && index + 1 < value.size) {
      const unsigned int low = static_cast<unsigned int>(value.value[index + 1]);
      if (LowSurrogate(low)) {
        code_point = 0x10000 + ((code_point - 0xd800) << 10) + (low - 0xdc00);
        ++index;
      }
    }
    if (BusinessWhitespace(code_point)) return true;
  }
  return false;
}

bool HasWhitespaceOnly(const DecodedText& value) noexcept;

bool OnlyWhitespace(const DecodedText& value) noexcept {
  return value.size == 0 || HasWhitespaceOnly(value);
}

bool HasWhitespaceOnly(const DecodedText& value) noexcept {
  for (size_t index = 0; index < value.size; ++index) {
    unsigned int code_point = static_cast<unsigned int>(value.value[index]);
    if (HighSurrogate(code_point) && index + 1 < value.size) {
      const unsigned int low = static_cast<unsigned int>(value.value[index + 1]);
      if (LowSurrogate(low)) {
        code_point = 0x10000 + ((code_point - 0xd800) << 10) + (low - 0xdc00);
        ++index;
      }
    }
    if (!BusinessWhitespace(code_point)) return false;
  }
  return true;
}

bool StrictDateLexeme(const DecodedText& value) noexcept {
  if (value.size != 19) return false;
  constexpr size_t separators[] = {4, 7, 10, 13, 16};
  constexpr wchar_t expected[] = {L'-', L'-', L' ', L':', L':'};
  constexpr size_t separator_count = sizeof(separators) / sizeof(separators[0]);
  for (size_t index = 0; index < separator_count; ++index) {
    if (value.value[separators[index]] != expected[index]) return false;
  }
  for (size_t index = 0; index < value.size; ++index) {
    bool separator = false;
    for (size_t candidate : separators) separator |= index == candidate;
    if (!separator && !Digit(value.value[index])) return false;
  }
  return true;
}

bool ExactString(const Document& document, const Span& span,
                 std::wstring_view expected) noexcept {
  if (span.kind != ValueKind::string || span.escaped ||
      span.end - span.begin != expected.size() + 2) return false;
  for (size_t index = 0; index < expected.size(); ++index) {
    if (document.raw[span.begin + 1 + index] != expected[index]) return false;
  }
  return true;
}

bool StrictInteger(const Document& document, const Span& span, int minimum,
                   int maximum, int& output) noexcept {
  if (span.kind != ValueKind::number || span.begin >= span.end) return false;
  size_t position = span.begin;
  bool negative = false;
  if (document.raw[position] == L'-') {
    negative = true;
    ++position;
  }
  if (position == span.end) return false;
  long long value = 0;
  for (; position < span.end; ++position) {
    const wchar_t digit = document.raw[position];
    if (!Digit(digit)) return false;
    const long long next = digit - L'0';
    if (value > 214748364LL ||
        (value == 214748364LL && next > 8)) return false;
    value = value * 10 + next;
  }
  if (negative) value = -value;
  if (value < minimum || value > maximum) return false;
  output = static_cast<int>(value);
  return true;
}

std::optional<Endpoint> ClassifyUrl(const Document& document, const Span& span,
                                  std::wstring_view origin,
                                  std::wstring_view prefix) noexcept {
  if (span.kind != ValueKind::string || span.escaped || origin.empty() ||
      origin.size() > 512 || prefix.empty() || prefix.size() > 128 ||
      origin.back() == L'/' || prefix.front() != L'/' || prefix.back() == L'/')
    return std::nullopt;
  const size_t begin = span.begin + 1;
  size_t end = span.end - 1;
  // Stop at '?': query values are neither decoded nor copied or interpreted.
  for (size_t cursor = begin; cursor < end; ++cursor) {
    if (document.raw[cursor] == L'?') {
      end = cursor;
      break;
    }
  }
  if (end - begin < origin.size() + prefix.size()) return std::nullopt;
  size_t cursor = begin;
  for (wchar_t value : origin) {
    if (document.raw[cursor++] != value) return std::nullopt;
  }
  for (wchar_t value : prefix) {
    if (document.raw[cursor++] != value) return std::nullopt;
  }
  const std::wstring_view path(document.raw + cursor, end - cursor);
  if (path == L"/paramdesign/scMyInfo/info") return Endpoint::profile;
  if (path == L"/personal/scCalendar/getPageUserList") return Endpoint::schedule;
  if (path == L"/mobile/item/enrolmentList") return Endpoint::activities;
  return std::nullopt;
}

bool TransportType(const Document& document, const Span& span) noexcept {
  return AsciiLiteral(document.raw, span, "XHR") ||
         AsciiLiteral(document.raw, span, "Fetch");
}

bool IsFalse(const Document& document, const Span& span) noexcept {
  return span.kind == ValueKind::boolean && RawLiteral(document.raw, span, "false");
}

// Compare the validated decimal lexeme with 200 without allocating a number
// string, converting arbitrary-size numbers, or admitting nonfinite values.
bool IsStatus200(const Document& document, const Span& span) noexcept {
  if (span.kind != ValueKind::number || document.raw[span.begin] == L'-')
    return false;
  size_t position = span.begin;
  bool fractional = false;
  int fractional_digits = 0;
  size_t significant_digits = 0;
  bool nonzero_seen = false;
  bool matches = true;
  while (position < span.end && document.raw[position] != L'e' &&
         document.raw[position] != L'E') {
    const wchar_t value = document.raw[position++];
    if (value == L'.') {
      fractional = true;
      continue;
    }
    if (fractional) ++fractional_digits;
    if (!nonzero_seen && value == L'0') continue;
    nonzero_seen = true;
    if ((significant_digits == 0 && value != L'2') ||
        (significant_digits != 0 && value != L'0')) matches = false;
    ++significant_digits;
  }
  int exponent = 0;
  bool negative_exponent = false;
  if (position < span.end) {
    ++position;
    if (document.raw[position] == L'+' || document.raw[position] == L'-') {
      negative_exponent = document.raw[position] == L'-';
      ++position;
    }
    for (; position < span.end; ++position) {
      if (exponent > 1000) return false;
      exponent = exponent * 10 + document.raw[position] - L'0';
    }
  }
  if (negative_exponent) exponent = -exponent;
  return nonzero_seen && matches &&
         static_cast<int>(significant_digits) - 1 + exponent - fractional_digits == 2;
}

bool FiniteNumber(const Document& document, const Span& span,
                  double& result) noexcept {
  if (span.kind != ValueKind::number) return false;
  // Only the selected timestamp's bounded ASCII number is converted. No
  // unknown metric name/value or business numeric value enters this buffer.
  std::array<char, kMaximumNumberChars> number{};
  const size_t length = span.end - span.begin;
  if (length > number.size()) return false;
  for (size_t index = 0; index < length; ++index)
    number[index] = static_cast<char>(document.raw[span.begin + index]);
  const auto converted = std::from_chars(number.data(), number.data() + length,
                                         result, std::chars_format::general);
  return converted.ec == std::errc{} && converted.ptr == number.data() + length &&
         std::isfinite(result);
}

class PrivateBodyBuffer {
 public:
  PrivateBodyBuffer() = default;
  PrivateBodyBuffer(const PrivateBodyBuffer&) = delete;
  PrivateBodyBuffer& operator=(const PrivateBodyBuffer&) = delete;
  ~PrivateBodyBuffer() { SecureErase(value_.data(), value_.size()); }

  bool Decode(const Document& document, const Span& body, DecodeAudit* audit) {
    if (body.kind != ValueKind::string) return false;
    const size_t maximum_decoded = body.end - body.begin - 2;
    if (maximum_decoded > kBodyProtocolChars) return false;
    // One allocation before any byte is decoded; push_back cannot relocate a
    // decoded body to another unwiped allocation.
    value_.reserve(maximum_decoded);
    if (audit) ++audit->transport_body_values;
    for (size_t position = body.begin + 1; position + 1 < body.end;) {
      wchar_t value = document.raw[position++];
      if (value == L'\\') {
        const wchar_t escape = document.raw[position++];
        switch (escape) {
          case L'"': value = L'"'; break;
          case L'\\': value = L'\\'; break;
          case L'/': value = L'/'; break;
          case L'b': value = L'\b'; break;
          case L'f': value = L'\f'; break;
          case L'n': value = L'\n'; break;
          case L'r': value = L'\r'; break;
          case L't': value = L'\t'; break;
          case L'u': {
            unsigned int unicode = 0;
            for (int digit = 0; digit < 4; ++digit) {
              const int hex = Hex(document.raw[position++]);
              if (hex < 0) return false;
              unicode = unicode * 16 + static_cast<unsigned int>(hex);
            }
            value = static_cast<wchar_t>(unicode);
            break;
          }
          default: return false;
        }
      }
      value_.push_back(value);
      if (audit) ++audit->transport_body_units;
    }
    return true;
  }

  const wchar_t* data() const noexcept { return value_.data(); }
  size_t size() const noexcept { return value_.size(); }

 private:
  std::vector<wchar_t> value_;
};

class BusinessJsonBuffer {
 public:
  explicit BusinessJsonBuffer(size_t limit) : limit_(limit) {
    value_.reserve(limit);
  }
  BusinessJsonBuffer(const BusinessJsonBuffer&) = delete;
  BusinessJsonBuffer& operator=(const BusinessJsonBuffer&) = delete;
  ~BusinessJsonBuffer() { SecureErase(value_.data(), value_.size()); }

  void Append(std::wstring_view text) {
    if (text.size() > limit_ - value_.size())
      throw std::length_error("business projection limit");
    value_.append(text);
  }
  void Append(wchar_t value) {
    if (value_.size() >= limit_)
      throw std::length_error("business projection limit");
    value_.push_back(value);
  }

  void AppendJsonText(const DecodedText& text) {
    Append(L'"');
    for (size_t index = 0; index < text.size; ++index) {
      const wchar_t value = text.value[index];
      if (value == L'"' || value == L'\\') Append(L'\\');
      Append(value);
    }
    Append(L'"');
  }

  void AppendInteger(int value) { Append(std::to_wstring(value)); }

  std::wstring Release() {
    std::wstring result;
    result.swap(value_);
    return result;
  }

 private:
  size_t limit_;
  std::wstring value_;
};

bool AppendBusinessString(const Document& document, const Span& span,
                          size_t maximum, bool allow_empty,
                          bool allow_whitespace_only, bool date_text,
                          bool reject_any_whitespace, BusinessJsonBuffer& output,
                          DecodeAudit* audit) {
  DecodedText text;
  if (!DecodeBoundedText(document, span, maximum, text, audit, true) ||
      HasControl(text) || (!allow_empty && OnlyWhitespace(text)) ||
      (!allow_whitespace_only && text.size != 0 && OnlyWhitespace(text)) ||
      (reject_any_whitespace && HasWhitespace(text)) ||
      (date_text && !StrictDateLexeme(text))) return false;
  output.AppendJsonText(text);
  return true;
}

bool AppendOptionalBusinessString(const Document& document, const Span& span,
                                  size_t maximum, bool allow_empty,
                                  bool allow_whitespace_only, bool date_text,
                                  BusinessJsonBuffer& output,
                                  DecodeAudit* audit) {
  if (span.kind == ValueKind::absent) return true;
  if (span.kind == ValueKind::null_value) {
    output.Append(L"null");
    return true;
  }
  return AppendBusinessString(document, span, maximum, allow_empty,
                             allow_whitespace_only, date_text, false, output,
                             audit);
}

SuccessKind Success(const Document& document, const Span& span) noexcept {
  if (span.kind == ValueKind::boolean) {
    if (RawLiteral(document.raw, span, "true")) return SuccessKind::true_value;
    if (RawLiteral(document.raw, span, "false")) return SuccessKind::false_value;
  }
  return SuccessKind::other;
}

ValueKind Combine(ValueKind accumulated, ValueKind next, bool first) noexcept {
  if (first) return next;
  return accumulated == next ? accumulated : ValueKind::mixed;
}

bool Records(const Document& document, const Span& array,
             ListProjection& projection, Rejection& reason) {
  Scanner scanner(document.raw, document.length, document.maximum, false,
                  document.malformed, document.depth_limit);
  scanner.position(array.begin);
  if (!scanner.Consume(L'[')) return false;
  scanner.SkipWhite();
  if (scanner.Peek() == L']') return true;
  while (true) {
    if (projection.count >= kMaximumRecords) {
      reason = Rejection::limit;
      return false;
    }
    Span record;
    if (!scanner.Value(record, 1)) {
      reason = scanner.rejection();
      return false;
    }
    std::array<Span, 5> fields{};
    if (!Fields(document, record,
                std::array<const char*, 5>{"id", "title", "date", "startTime", "endTime"},
                fields)) return false;
    const bool first = projection.count == 0;
    projection.id = Combine(projection.id, fields[0].kind, first);
    projection.title = Combine(projection.title, fields[1].kind, first);
    projection.date = Combine(projection.date, fields[2].kind, first);
    projection.startTime = Combine(projection.startTime, fields[3].kind, first);
    projection.endTime = Combine(projection.endTime, fields[4].kind, first);
    ++projection.count;
    scanner.SkipWhite();
    if (scanner.Peek() == L']') return scanner.position() + 1 == array.end;
    if (!scanner.Consume(L',')) return false;
    scanner.SkipWhite();
  }
}

ParseResult<FrameBinding> FrameTree(const wchar_t* raw, size_t length,
                                   DecodeAudit* audit) {
  Document document{raw, length, kMetadataChars, Rejection::transport};
  if (!document.Validate()) return Reject<FrameBinding>(document.rejection);
  std::array<Span, 1> tree{};
  std::array<Span, 1> frame{};
  std::array<Span, 2> identifiers{};
  if (!Fields(document, document.root, std::array<const char*, 1>{"frameTree"}, tree) ||
      !Fields(document, tree[0], std::array<const char*, 1>{"frame"}, frame) ||
      !Fields(document, frame[0], std::array<const char*, 2>{"id", "loaderId"}, identifiers))
    return Reject<FrameBinding>(Rejection::frame);
  FrameBinding binding;
  if (!DecodeIdentifier(document, identifiers[0], binding.frame, audit))
    return Reject<FrameBinding>(Rejection::frame);
  if (!DecodeIdentifier(document, identifiers[1], binding.loader, audit))
    return Reject<FrameBinding>(Rejection::loader);
  return {std::move(binding), Rejection::none};
}

ParseResult<std::wstring> RequestId(const wchar_t* raw, size_t length,
                                    DecodeAudit* audit) {
  Document document{raw, length, kMetadataChars, Rejection::transport};
  if (!document.Validate()) return Reject<std::wstring>(document.rejection);
  std::array<Span, 1> identifier{};
  if (!Fields(document, document.root,
              std::array<const char*, 1>{"requestId"}, identifier))
    return Reject<std::wstring>(Rejection::transport);
  std::wstring result;
  if (!DecodeIdentifier(document, identifier[0], result, audit))
    return Reject<std::wstring>(Rejection::transport);
  return {std::move(result), Rejection::none};
}

bool ValidIdentifierView(std::wstring_view value) noexcept {
  if (value.empty() || value.size() > kMaximumIdentifierChars) return false;
  for (wchar_t character : value) {
    if (!IdentifierCharacter(character)) return false;
  }
  return true;
}

ParseResult<DefaultContext> DefaultContextEvent(
    const wchar_t* raw, size_t length, std::wstring_view current_frame,
    std::wstring_view allowed_origin, DecodeAudit* audit) {
  Document document{raw, length, kMetadataChars, Rejection::transport};
  if (!document.Validate()) return Reject<DefaultContext>(document.rejection);
  if (!ValidIdentifierView(current_frame) || allowed_origin.empty() ||
      allowed_origin.size() > 512) return Reject<DefaultContext>(Rejection::target);
  std::array<Span, 1> root{};
  if (!Fields(document, document.root, std::array<const char*, 1>{"context"}, root) ||
      root[0].kind != ValueKind::object) return Reject<DefaultContext>(Rejection::target);
  std::array<Span, 4> context{};
  if (!Fields(document, root[0],
              std::array<const char*, 4>{"id", "uniqueId", "origin", "auxData"},
              context) || context[3].kind != ValueKind::object)
    return Reject<DefaultContext>(Rejection::target);
  std::array<Span, 2> aux{};
  if (!Fields(document, context[3],
              std::array<const char*, 2>{"frameId", "isDefault"}, aux))
    return Reject<DefaultContext>(Rejection::target);
  int id = 0;
  if (!StrictInteger(document, context[0], 1, 2147483647, id) ||
      !ExactString(document, context[2], allowed_origin) ||
      !RawLiteral(raw, aux[1], "true"))
    return Reject<DefaultContext>(Rejection::target);
  WipedString frame;
  if (!DecodeIdentifier(document, aux[0], frame.value(), audit))
    return Reject<DefaultContext>(Rejection::frame);
  if (std::wstring_view(frame.value()) != current_frame)
    return Reject<DefaultContext>(Rejection::target);
  DefaultContext result;
  result.id = id;
  if (!DecodeIdentifier(document, context[1], result.unique_id, audit))
    return Reject<DefaultContext>(Rejection::target);
  return {std::move(result), Rejection::none};
}

ParseResult<bool> ContextDestroyed(const wchar_t* raw, size_t length,
    int context_id, std::wstring_view unique_id) {
  Document document{raw, length, kMetadataChars, Rejection::transport};
  if (!document.Validate()) return Reject<bool>(document.rejection);
  std::array<Span, 2> fields{};
  if (!Fields(document, document.root,
      std::array<const char*,2>{"executionContextId", "executionContextUniqueId"}, fields))
    return Reject<bool>(Rejection::transport);
  const bool has_id = fields[0].kind != ValueKind::absent;
  const bool has_unique = fields[1].kind != ValueKind::absent;
  int id = 0;
  if ((!has_id && !has_unique) ||
      (has_id && !StrictInteger(document, fields[0], 1, 2147483647, id)) ||
      (has_unique && fields[1].kind != ValueKind::string)) return Reject<bool>(Rejection::transport);
  WipedString observed_unique;
  if (has_unique && !DecodeIdentifier(document, fields[1], observed_unique.value(), nullptr))
    return Reject<bool>(Rejection::transport);
  const bool id_matches = has_id && context_id > 0 && id == context_id;
  const bool unique_matches = has_unique && !unique_id.empty() && observed_unique.value() == unique_id;
  if (has_id && has_unique && context_id > 0 && id_matches != unique_matches)
    return Reject<bool>(Rejection::stale);
  return {has_unique ? unique_matches : id_matches, Rejection::none};
}

ParseResult<std::wstring> StepScript(const wchar_t* raw, size_t length,
                                    std::wstring_view marker, int context_id,
                                    DecodeAudit* audit) {
  Document document{raw, length, kMetadataChars, Rejection::transport};
  if (!document.Validate()) return Reject<std::wstring>(document.rejection);
  if (marker.empty() || marker.size() > 2048 || context_id <= 0)
    return Reject<std::wstring>(Rejection::target);
  std::array<Span, 3> fields{};
  if (!Fields(document, document.root,
              std::array<const char*, 3>{"scriptId", "url", "executionContextId"},
              fields)) return Reject<std::wstring>(Rejection::target);
  int observed_context = 0;
  if (!ExactString(document, fields[1], marker) ||
      !StrictInteger(document, fields[2], 1, 2147483647, observed_context) ||
      observed_context != context_id) return Reject<std::wstring>(Rejection::target);
  std::wstring script_id;
  if (!DecodeIdentifier(document, fields[0], script_id, audit))
    return Reject<std::wstring>(Rejection::target);
  return {std::move(script_id), Rejection::none};
}

ParseResult<std::wstring> CompiledScriptId(const wchar_t* raw, size_t length,
                                          DecodeAudit* audit) {
  Document document{raw, length, kMetadataChars, Rejection::transport};
  if (!document.Validate()) return Reject<std::wstring>(document.rejection);
  std::array<Span, 2> fields{};
  if (!Fields(document, document.root,
              std::array<const char*, 2>{"scriptId", "exceptionDetails"}, fields) ||
      fields[1].kind != ValueKind::absent) return Reject<std::wstring>(Rejection::transport);
  std::wstring script_id;
  if (!DecodeIdentifier(document, fields[0], script_id, audit))
    return Reject<std::wstring>(Rejection::transport);
  return {std::move(script_id), Rejection::none};
}

ParseResult<bool> InitiatorScript(const wchar_t* raw, size_t length,
                                 std::wstring_view registered_script_id,
                                 DecodeAudit* audit) {
  Document document{raw, length, kMetadataChars, Rejection::transport};
  if (!document.Validate(false, kMaximumInitiatorJsonDepth))
    return Reject<bool>(document.rejection);
  if (!ValidIdentifierView(registered_script_id)) return Reject<bool>(Rejection::target);
  std::array<Span, 1> root{};
  if (!Fields(document, document.root, std::array<const char*, 1>{"initiator"}, root) ||
      root[0].kind != ValueKind::object) return Reject<bool>(Rejection::target);
  std::array<Span, 2> initiator{};
  if (!Fields(document, root[0], std::array<const char*, 2>{"type", "stack"}, initiator) ||
      !ExactString(document, initiator[0], L"script") ||
      initiator[1].kind != ValueKind::object)
    return Reject<bool>(Rejection::target);

  Span stack = initiator[1];
  for (size_t level = 0; level < 32; ++level) {
    std::array<Span, 3> stack_fields{};
    if (!Fields(document, stack,
                std::array<const char*, 3>{"callFrames", "parent", "parentId"},
                stack_fields) || stack_fields[0].kind != ValueKind::array)
      return Reject<bool>(Rejection::transport);
    Scanner scanner(raw, length, kMetadataChars, false, Rejection::transport);
    scanner.position(stack_fields[0].begin);
    if (!scanner.Consume(L'[')) return Reject<bool>(Rejection::transport);
    scanner.SkipWhite();
    if (scanner.Peek() == L']') return Reject<bool>(Rejection::target);
    size_t frames = 0;
    bool matched = false;
    while (true) {
      if (++frames > 128) return Reject<bool>(Rejection::limit);
      Span frame;
      if (!scanner.Value(frame, 2) || frame.kind != ValueKind::object)
        return Reject<bool>(Rejection::transport);
      std::array<Span, 5> call_frame{};
      if (!Fields(document, frame,
                  std::array<const char*, 5>{"scriptId", "functionName", "url",
                                             "lineNumber", "columnNumber"},
                  call_frame) ||
          call_frame[0].kind != ValueKind::string ||
          call_frame[1].kind != ValueKind::string ||
          call_frame[2].kind != ValueKind::string ||
          call_frame[3].kind != ValueKind::number ||
          call_frame[4].kind != ValueKind::number)
        return Reject<bool>(Rejection::transport);
      int ignored_line = 0;
      int ignored_column = 0;
      if (!StrictInteger(document, call_frame[3], 0, 2147483647, ignored_line) ||
          !StrictInteger(document, call_frame[4], 0, 2147483647, ignored_column))
        return Reject<bool>(Rejection::transport);
      if (!matched) {
        WipedString observed_id;
        if (!DecodeIdentifier(document, call_frame[0], observed_id.value(), audit))
          return Reject<bool>(Rejection::transport);
        matched = std::wstring_view(observed_id.value()) == registered_script_id;
      }
      scanner.SkipWhite();
      if (scanner.Peek() == L']') {
        if (scanner.position() + 1 != stack_fields[0].end)
          return Reject<bool>(Rejection::transport);
        break;
      }
      if (!scanner.Consume(L',')) return Reject<bool>(Rejection::transport);
      scanner.SkipWhite();
    }
    if (matched) return {true, Rejection::none};
    const Span parent = stack_fields[1];
    const Span parent_id = stack_fields[2];
    if (parent_id.kind != ValueKind::absent || parent.kind == ValueKind::absent)
      return Reject<bool>(Rejection::target);
    if (parent.kind != ValueKind::object) return Reject<bool>(Rejection::transport);
    if (level == 31) return Reject<bool>(Rejection::limit);
    stack = parent;
  }
  return Reject<bool>(Rejection::limit);
}

ParseResult<std::wstring> RemoteObjectId(const wchar_t* raw, size_t length,
                                        DecodeAudit* audit) {
  Document document{raw, length, kMetadataChars, Rejection::transport};
  if (!document.Validate()) return Reject<std::wstring>(document.rejection);
  std::array<Span, 2> root{};
  if (!Fields(document, document.root,
              std::array<const char*, 2>{"result", "exceptionDetails"}, root) ||
      root[1].kind != ValueKind::absent || root[0].kind != ValueKind::object)
    return Reject<std::wstring>(Rejection::transport);
  std::array<Span, 2> result_fields{};
  if (!Fields(document, root[0], std::array<const char*, 2>{"type", "objectId"},
              result_fields) || !ExactString(document, result_fields[0], L"object"))
    return Reject<std::wstring>(Rejection::transport);
  DecodedText object_id;
  if (!DecodeBoundedText(document, result_fields[1], kMaximumPlatformObjectIdChars,
                         object_id, audit, false) || object_id.size == 0 ||
      HasControl(object_id)) return Reject<std::wstring>(Rejection::transport);
  return {std::wstring(object_id.view()), Rejection::none};
}

ParseResult<int> RemoteStatus(const wchar_t* raw, size_t length) {
  Document document{raw, length, kMetadataChars, Rejection::transport};
  if (!document.Validate()) return Reject<int>(document.rejection);
  std::array<Span, 2> root{};
  if (!Fields(document, document.root,
              std::array<const char*, 2>{"result", "exceptionDetails"}, root) ||
      root[1].kind != ValueKind::absent || root[0].kind != ValueKind::object)
    return Reject<int>(Rejection::transport);
  std::array<Span, 2> fields{};
  if (!Fields(document, root[0], std::array<const char*, 2>{"type", "value"}, fields) ||
      !ExactString(document, fields[0], L"number"))
    return Reject<int>(Rejection::transport);
  int status = -1;
  if (!StrictInteger(document, fields[1], 0, 2, status))
    return Reject<int>(Rejection::transport);
  return {status, Rejection::none};
}

ParseResult<double> MonotonicBarrier(const wchar_t* raw, size_t length) {
  Document document{raw, length, kMetadataChars, Rejection::transport};
  if (!document.Validate()) return Reject<double>(document.rejection);
  std::array<Span, 1> metrics{};
  if (!Fields(document, document.root,
              std::array<const char*, 1>{"metrics"}, metrics) ||
      metrics[0].kind != ValueKind::array)
    return Reject<double>(Rejection::transport);
  Scanner scanner(raw, length, kMetadataChars, false, Rejection::transport);
  scanner.position(metrics[0].begin);
  if (!scanner.Consume(L'[')) return Reject<double>(Rejection::transport);
  scanner.SkipWhite();
  if (scanner.Peek() == L']') return Reject<double>(Rejection::transport);
  bool found = false;
  double timestamp = 0;
  while (true) {
    Span metric;
    std::array<Span, 2> fields{};
    if (!scanner.Value(metric, 1) ||
        !Fields(document, metric, std::array<const char*, 2>{"name", "value"}, fields))
      return Reject<double>(Rejection::transport);
    if (AsciiLiteral(raw, fields[0], "Timestamp")) {
      if (found || !FiniteNumber(document, fields[1], timestamp) || timestamp <= 0)
        return Reject<double>(Rejection::transport);
      found = true;
    }
    scanner.SkipWhite();
    if (scanner.Peek() == L']') break;
    if (!scanner.Consume(L',')) return Reject<double>(Rejection::transport);
    scanner.SkipWhite();
  }
  if (!found) return Reject<double>(Rejection::transport);
  return {timestamp, Rejection::none};
}

ParseResult<RequestMetadata> Request(const wchar_t* raw, size_t length,
                                     std::wstring_view origin,
                                     std::wstring_view prefix, DecodeAudit* audit) {
  Document document{raw, length, kMetadataChars, Rejection::transport};
  if (!document.Validate()) return Reject<RequestMetadata>(document.rejection);
  std::array<Span, 7> root{};
  if (!Fields(document, document.root,
              std::array<const char*, 7>{"requestId", "frameId", "loaderId", "type", "request", "redirectResponse", "timestamp"},
              root)) return Reject<RequestMetadata>(Rejection::transport);
  std::array<Span, 4> request{};
  if (!Fields(document, root[4],
              std::array<const char*, 4>{"method", "url", "postData", "hasPostData"}, request))
    return Reject<RequestMetadata>(Rejection::target);
  const auto endpoint = ClassifyUrl(document, request[1], origin, prefix);
  if (!endpoint) return Reject<RequestMetadata>(Rejection::target);
  if (root[5].kind != ValueKind::absent)
    return Reject<RequestMetadata>(Rejection::redirect);
  if (!AsciiLiteral(raw, request[0], "GET"))
    return Reject<RequestMetadata>(Rejection::method);
  if (request[2].kind != ValueKind::absent ||
      (request[3].kind != ValueKind::absent && !IsFalse(document, request[3])))
    return Reject<RequestMetadata>(Rejection::method);
  if (!TransportType(document, root[3]))
    return Reject<RequestMetadata>(Rejection::worker);
  RequestMetadata metadata;
  metadata.endpoint = *endpoint;
  if (!FiniteNumber(document, root[6], metadata.timestamp) || metadata.timestamp < 0 ||
      raw[root[6].begin] == L'-')
    return Reject<RequestMetadata>(Rejection::transport);
  if (!DecodeIdentifier(document, root[0], metadata.request_id, audit))
    return Reject<RequestMetadata>(Rejection::transport);
  if (!DecodeIdentifier(document, root[1], metadata.frame_id, audit))
    return Reject<RequestMetadata>(Rejection::frame);
  if (!DecodeIdentifier(document, root[2], metadata.loader_id, audit))
    return Reject<RequestMetadata>(Rejection::loader);
  return {std::move(metadata), Rejection::none};
}

ParseResult<ResponseMetadata> Response(const wchar_t* raw, size_t length,
                                      std::wstring_view origin,
                                      std::wstring_view prefix, DecodeAudit* audit) {
  Document document{raw, length, kMetadataChars, Rejection::transport};
  if (!document.Validate()) return Reject<ResponseMetadata>(document.rejection);
  std::array<Span, 5> root{};
  if (!Fields(document, document.root,
              std::array<const char*, 5>{"requestId", "frameId", "loaderId", "type", "response"}, root))
    return Reject<ResponseMetadata>(Rejection::transport);
  std::array<Span, 6> response{};
  if (!Fields(document, root[4],
              std::array<const char*, 6>{"url", "status", "mimeType", "fromServiceWorker", "fromDiskCache", "fromPrefetchCache"},
              response)) return Reject<ResponseMetadata>(Rejection::target);
  const auto endpoint = ClassifyUrl(document, response[0], origin, prefix);
  if (!endpoint) return Reject<ResponseMetadata>(Rejection::target);
  if (!TransportType(document, root[3]))
    return Reject<ResponseMetadata>(Rejection::worker);
  if (!IsFalse(document, response[3])) return Reject<ResponseMetadata>(Rejection::worker);
  if (!IsFalse(document, response[4]) || !IsFalse(document, response[5]))
    return Reject<ResponseMetadata>(Rejection::cache);
  if (!IsStatus200(document, response[1]) ||
      !AsciiLiteral(raw, response[2], "application/json"))
    return Reject<ResponseMetadata>(Rejection::transport);
  ResponseMetadata metadata;
  metadata.endpoint = *endpoint;
  if (!DecodeIdentifier(document, root[0], metadata.request_id, audit))
    return Reject<ResponseMetadata>(Rejection::transport);
  if (!DecodeIdentifier(document, root[1], metadata.frame_id, audit))
    return Reject<ResponseMetadata>(Rejection::frame);
  if (!DecodeIdentifier(document, root[2], metadata.loader_id, audit))
    return Reject<ResponseMetadata>(Rejection::loader);
  return {std::move(metadata), Rejection::none};
}

ParseResult<BodyProjection> Body(const wchar_t* raw, size_t length,
                                Endpoint endpoint, DecodeAudit* audit) {
  if (endpoint != Endpoint::profile && endpoint != Endpoint::schedule &&
      endpoint != Endpoint::activities) return Reject<BodyProjection>(Rejection::target);
  Document protocol{raw, length, kBodyProtocolChars, Rejection::body};
  if (!protocol.Validate()) return Reject<BodyProjection>(protocol.rejection);
  std::array<Span, 2> envelope{};
  size_t member_count = 0;
  if (!Fields(protocol, protocol.root, std::array<const char*, 2>{"body", "base64Encoded"},
              envelope, &member_count) || member_count != 2 ||
      envelope[0].kind != ValueKind::string || !IsFalse(protocol, envelope[1]))
    return Reject<BodyProjection>(Rejection::body);
  PrivateBodyBuffer buffer;
  if (!buffer.Decode(protocol, envelope[0], audit))
    return Reject<BodyProjection>(Rejection::body);
  Document document{buffer.data(), buffer.size(), kBodyProtocolChars, Rejection::body};
  if (!document.Validate(true)) return Reject<BodyProjection>(document.rejection);
  std::array<Span, 3> root{};
  if (!Fields(document, document.root,
              std::array<const char*, 3>{"success", "code", "result"}, root))
    return Reject<BodyProjection>(Rejection::body);
  BodyProjection projection;
  projection.endpoint = endpoint;
  if (endpoint == Endpoint::profile) {
    projection.profile.success = Success(document, root[0]);
    projection.profile.code = root[1].kind;
    projection.profile.result = root[2].kind;
    if (root[2].kind == ValueKind::object) {
      std::array<Span, 2> fields{};
      if (!Fields(document, root[2], std::array<const char*, 2>{"loginCode", "username"}, fields))
        return Reject<BodyProjection>(Rejection::body);
      projection.profile.loginCode = fields[0].kind;
      projection.profile.username = fields[1].kind;
    }
  } else {
    projection.list.success = Success(document, root[0]);
    projection.list.code = root[1].kind;
    projection.list.result = root[2].kind;
    if (root[2].kind == ValueKind::object) {
      std::array<Span, 2> fields{};
      if (!Fields(document, root[2], std::array<const char*, 2>{"records", "total"}, fields))
        return Reject<BodyProjection>(Rejection::body);
      projection.list.records = fields[0].kind;
      projection.list.total = fields[1].kind;
      Rejection reason = Rejection::body;
      if (fields[0].kind == ValueKind::array && !Records(document, fields[0], projection.list, reason))
        return Reject<BodyProjection>(reason);
    }
  }
  return {projection, Rejection::none};
}

bool ActivityRecord(const Document& document, const Span& record,
                    BusinessJsonBuffer& output, DecodeAudit* audit) {
  std::array<Span, 7> fields{};
  if (!Fields(document, record,
              std::array<const char*, 7>{"id", "itemName", "st", "et",
                                         "applySt", "applyEt", "placeInfo"},
              fields)) return false;
  output.Append(L"{\"id\":");
  if (!AppendBusinessString(document, fields[0], 256, false, false, false,
                            false, output, audit)) return false;
  output.Append(L",\"itemName\":");
  if (!AppendBusinessString(document, fields[1], 2048, false, false, false,
                            false, output, audit)) return false;
  output.Append(L",\"st\":");
  if (!AppendBusinessString(document, fields[2], 19, false, false, true,
                            false, output, audit)) return false;
  output.Append(L",\"et\":");
  if (!AppendBusinessString(document, fields[3], 19, false, false, true,
                            false, output, audit)) return false;
  if (fields[4].kind != ValueKind::absent) {
    output.Append(L",\"applySt\":");
    if (!AppendOptionalBusinessString(document, fields[4], 19, false, false,
                                      true, output, audit)) return false;
  }
  if (fields[5].kind != ValueKind::absent) {
    output.Append(L",\"applyEt\":");
    if (!AppendOptionalBusinessString(document, fields[5], 19, false, false,
                                      true, output, audit)) return false;
  }
  if (fields[6].kind != ValueKind::absent) {
    output.Append(L",\"placeInfo\":");
    if (!AppendOptionalBusinessString(document, fields[6], 2048, true, true,
                                      false, output, audit)) return false;
  }
  output.Append(L"}");
  return true;
}

bool CalendarRecord(const Document& document, const Span& record,
                    BusinessJsonBuffer& output, DecodeAudit* audit) {
  std::array<Span, 6> fields{};
  if (!Fields(document, record,
              std::array<const char*, 6>{"id", "title", "place", "startTime",
                                         "endTime", "itemId"},
              fields)) return false;
  output.Append(L"{\"id\":");
  if (!AppendBusinessString(document, fields[0], 256, false, false, false,
                            false, output, audit)) return false;
  output.Append(L",\"title\":");
  if (!AppendBusinessString(document, fields[1], 2048, false, false, false,
                            false, output, audit)) return false;
  output.Append(L",\"place\":");
  if (!AppendBusinessString(document, fields[2], 2048, true, true, false,
                            false, output, audit)) return false;
  output.Append(L",\"startTime\":");
  if (!AppendBusinessString(document, fields[3], 19, false, false, true,
                            false, output, audit)) return false;
  output.Append(L",\"endTime\":");
  if (!AppendBusinessString(document, fields[4], 19, false, false, true,
                            false, output, audit)) return false;
  if (fields[5].kind != ValueKind::absent) {
    output.Append(L",\"itemId\":");
    if (!AppendOptionalBusinessString(document, fields[5], 256, true, false,
                                      false, output, audit)) return false;
  }
  output.Append(L"}");
  return true;
}

bool BusinessRecords(const Document& document, const Span& array,
                     Endpoint endpoint, BusinessJsonBuffer& output,
                     DecodeAudit* audit, Rejection& reason, size_t& count) {
  if (array.kind != ValueKind::array ||
      (endpoint != Endpoint::schedule && endpoint != Endpoint::activities))
    return false;
  Scanner scanner(document.raw, document.length, document.maximum, false,
                  document.malformed, document.depth_limit);
  scanner.position(array.begin);
  if (!scanner.Consume(L'[')) return false;
  scanner.SkipWhite();
  output.Append(L"[");
  if (scanner.Peek() == L']') {
    if (scanner.position() + 1 != array.end) return false;
    output.Append(L"]");
    count = 0;
    return true;
  }
  count = 0;
  while (true) {
    if (++count > kMaximumBusinessRecords) {
      reason = Rejection::limit;
      return false;
    }
    Span record;
    if (!scanner.Value(record, 1) || record.kind != ValueKind::object) return false;
    if (count > 1) output.Append(L",");
    const bool projected = endpoint == Endpoint::activities
        ? ActivityRecord(document, record, output, audit)
        : CalendarRecord(document, record, output, audit);
    if (!projected) return false;
    scanner.SkipWhite();
    if (scanner.Peek() == L']') {
      if (scanner.position() + 1 != array.end) return false;
      output.Append(L"]");
      return true;
    }
    if (!scanner.Consume(L',')) return false;
    scanner.SkipWhite();
  }
}

ParseResult<std::wstring> BusinessBody(const wchar_t* raw, size_t length,
                                      Endpoint endpoint, DecodeAudit* audit) {
  if (endpoint != Endpoint::profile && endpoint != Endpoint::schedule &&
      endpoint != Endpoint::activities) return Reject<std::wstring>(Rejection::target);
  Document protocol{raw, length, kBodyProtocolChars, Rejection::body};
  if (!protocol.Validate()) return Reject<std::wstring>(protocol.rejection);
  std::array<Span, 2> envelope{};
  size_t member_count = 0;
  if (!Fields(protocol, protocol.root,
              std::array<const char*, 2>{"body", "base64Encoded"}, envelope,
              &member_count) || member_count != 2 ||
      envelope[0].kind != ValueKind::string || !IsFalse(protocol, envelope[1]))
    return Reject<std::wstring>(Rejection::body);

  PrivateBodyBuffer buffer;
  if (!buffer.Decode(protocol, envelope[0], audit))
    return Reject<std::wstring>(Rejection::body);
  Document document{buffer.data(), buffer.size(), kBodyProtocolChars,
                    Rejection::body};
  if (!document.Validate(true)) return Reject<std::wstring>(document.rejection);
  std::array<Span, 3> root{};
  if (!Fields(document, document.root,
              std::array<const char*, 3>{"success", "code", "result"}, root) ||
      Success(document, root[0]) != SuccessKind::true_value ||
      !IsStatus200(document, root[1]) || root[2].kind != ValueKind::object)
    return Reject<std::wstring>(Rejection::body);

  BusinessJsonBuffer output(buffer.size());
  output.Append(L"{\"success\":true,\"code\":200,\"result\":");
  if (endpoint == Endpoint::profile) {
    std::array<Span, 1> fields{};
    if (!Fields(document, root[2], std::array<const char*, 1>{"username"}, fields))
      return Reject<std::wstring>(Rejection::body);
    output.Append(L"{\"username\":");
    if (!AppendBusinessString(document, fields[0], 64, false, false, false,
                              true, output, audit))
      return Reject<std::wstring>(Rejection::body);
    output.Append(L"}}");
  } else {
    std::array<Span, 2> fields{};
    if (!Fields(document, root[2],
                std::array<const char*, 2>{"records", "total"}, fields) ||
        fields[0].kind != ValueKind::array) return Reject<std::wstring>(Rejection::body);
    int total = 0;
    if (!StrictInteger(document, fields[1], 0, 10000, total))
      return Reject<std::wstring>(Rejection::body);
    output.Append(L"{\"records\":");
    Rejection reason = Rejection::body;
    size_t count = 0;
    if (!BusinessRecords(document, fields[0], endpoint, output, audit, reason, count))
      return Reject<std::wstring>(reason);
    output.Append(L",\"total\":");
    output.AppendInteger(total);
    output.Append(L"}}");
  }
  return {output.Release(), Rejection::none};
}

}  // namespace

const char* RejectionLabel(Rejection value) noexcept {
  switch (value) {
    case Rejection::none: return "none";
    case Rejection::target: return "target";
    case Rejection::method: return "method";
    case Rejection::frame: return "frame";
    case Rejection::loader: return "loader";
    case Rejection::redirect: return "redirect";
    case Rejection::worker: return "worker";
    case Rejection::cache: return "cache";
    case Rejection::transport: return "transport";
    case Rejection::limit: return "limit";
    case Rejection::body: return "body";
    case Rejection::stale: return "stale";
  }
  return "transport";
}

const char* ValueKindLabel(ValueKind value) noexcept {
  switch (value) {
    case ValueKind::absent: return "absent";
    case ValueKind::null_value: return "null";
    case ValueKind::boolean: return "boolean";
    case ValueKind::number: return "number";
    case ValueKind::string: return "string";
    case ValueKind::array: return "array";
    case ValueKind::object: return "object";
    case ValueKind::mixed: return "mixed";
  }
  return "absent";
}

const char* SuccessKindLabel(SuccessKind value) noexcept {
  switch (value) {
    case SuccessKind::unobserved: return "unobserved";
    case SuccessKind::true_value: return "true";
    case SuccessKind::false_value: return "false";
    case SuccessKind::other: return "other";
  }
  return "other";
}

ParseResult<FrameBinding> ParseFrameTree(const wchar_t* raw, size_t length,
                                       DecodeAudit* audit) {
  try {
    return FrameTree(raw, length, audit);
  } catch (const std::bad_alloc&) {
    return Reject<FrameBinding>(Rejection::limit);
  } catch (const std::length_error&) {
    return Reject<FrameBinding>(Rejection::limit);
  }
}

ParseResult<DefaultContext> ParseDefaultContext(
    const wchar_t* raw, size_t length, std::wstring_view frame,
    std::wstring_view origin, DecodeAudit* audit) {
  try {
    return DefaultContextEvent(raw, length, frame, origin, audit);
  } catch (const std::bad_alloc&) {
    return Reject<DefaultContext>(Rejection::limit);
  } catch (const std::length_error&) {
    return Reject<DefaultContext>(Rejection::limit);
  }
}

ParseResult<bool> IsContextDestroyed(const wchar_t* raw, size_t length,
    int context_id, std::wstring_view unique_id) {
  try { return ContextDestroyed(raw, length, context_id, unique_id); }
  catch (...) { return Reject<bool>(Rejection::limit); }
}

ParseResult<std::wstring> ParseWithinDocumentFrame(const wchar_t* raw,
    size_t length, DecodeAudit* audit) {
  try {
    Document document{raw, length, kMetadataChars, Rejection::transport};
    if (!document.Validate()) return Reject<std::wstring>(document.rejection);
    std::array<Span, 1> identifier{};
    if (!Fields(document, document.root,
        std::array<const char*, 1>{"frameId"}, identifier))
      return Reject<std::wstring>(Rejection::frame);
    std::wstring frame;
    if (!DecodeIdentifier(document, identifier[0], frame, audit))
      return Reject<std::wstring>(Rejection::frame);
    return {std::move(frame), Rejection::none};
  } catch (...) { return Reject<std::wstring>(Rejection::limit); }
}

ParseResult<std::wstring> ParseRequestId(const wchar_t* raw, size_t length,
                                       DecodeAudit* audit) {
  try {
    return RequestId(raw, length, audit);
  } catch (const std::bad_alloc&) {
    return Reject<std::wstring>(Rejection::limit);
  } catch (const std::length_error&) {
    return Reject<std::wstring>(Rejection::limit);
  }
}

ParseResult<std::wstring> ParseStepScript(const wchar_t* raw, size_t length,
                                         std::wstring_view marker,
                                         int context_id, DecodeAudit* audit) {
  try {
    return StepScript(raw, length, marker, context_id, audit);
  } catch (const std::bad_alloc&) {
    return Reject<std::wstring>(Rejection::limit);
  } catch (const std::length_error&) {
    return Reject<std::wstring>(Rejection::limit);
  }
}

ParseResult<std::wstring> ParseCompiledScriptId(const wchar_t* raw,
                                               size_t length,
                                               DecodeAudit* audit) {
  try {
    return CompiledScriptId(raw, length, audit);
  } catch (const std::bad_alloc&) {
    return Reject<std::wstring>(Rejection::limit);
  } catch (const std::length_error&) {
    return Reject<std::wstring>(Rejection::limit);
  }
}

ParseResult<bool> HasInitiatorScript(const wchar_t* raw, size_t length,
                                    std::wstring_view script_id,
                                    DecodeAudit* audit) {
  try {
    return InitiatorScript(raw, length, script_id, audit);
  } catch (const std::bad_alloc&) {
    return Reject<bool>(Rejection::limit);
  } catch (const std::length_error&) {
    return Reject<bool>(Rejection::limit);
  }
}

ParseResult<std::wstring> ParseRemoteObjectId(const wchar_t* raw, size_t length,
                                            DecodeAudit* audit) {
  try {
    return RemoteObjectId(raw, length, audit);
  } catch (const std::bad_alloc&) {
    return Reject<std::wstring>(Rejection::limit);
  } catch (const std::length_error&) {
    return Reject<std::wstring>(Rejection::limit);
  }
}

ParseResult<int> ParseRemoteStatus(const wchar_t* raw, size_t length,
                                  DecodeAudit* audit) {
  (void)audit;
  try {
    return RemoteStatus(raw, length);
  } catch (const std::bad_alloc&) {
    return Reject<int>(Rejection::limit);
  } catch (const std::length_error&) {
    return Reject<int>(Rejection::limit);
  }
}

ParseResult<double> ParseMonotonicBarrier(const wchar_t* raw, size_t length,
                                        DecodeAudit* audit) {
  // No string in this protocol is selected for decoding.
  (void)audit;
  try {
    return MonotonicBarrier(raw, length);
  } catch (const std::bad_alloc&) {
    return Reject<double>(Rejection::limit);
  } catch (const std::length_error&) {
    return Reject<double>(Rejection::limit);
  }
}

ParseResult<RequestMetadata> ParseRequest(const wchar_t* raw, size_t length,
                                        std::wstring_view business_origin,
                                        std::wstring_view business_prefix,
                                        DecodeAudit* audit) {
  try {
    return Request(raw, length, business_origin, business_prefix, audit);
  } catch (const std::bad_alloc&) {
    return Reject<RequestMetadata>(Rejection::limit);
  } catch (const std::length_error&) {
    return Reject<RequestMetadata>(Rejection::limit);
  }
}

ParseResult<ResponseMetadata> ParseResponse(const wchar_t* raw, size_t length,
                                          std::wstring_view business_origin,
                                          std::wstring_view business_prefix,
                                          DecodeAudit* audit) {
  try {
    return Response(raw, length, business_origin, business_prefix, audit);
  } catch (const std::bad_alloc&) {
    return Reject<ResponseMetadata>(Rejection::limit);
  } catch (const std::length_error&) {
    return Reject<ResponseMetadata>(Rejection::limit);
  }
}

ParseResult<BodyProjection> ProjectResponseBody(const wchar_t* raw, size_t length,
                                              Endpoint endpoint, DecodeAudit* audit) {
  try {
    return Body(raw, length, endpoint, audit);
  } catch (const std::bad_alloc&) {
    return Reject<BodyProjection>(Rejection::limit);
  } catch (const std::length_error&) {
    return Reject<BodyProjection>(Rejection::limit);
  }
}

ParseResult<std::wstring> ProjectBusinessResponseBody(
    const wchar_t* raw, size_t length, Endpoint endpoint, DecodeAudit* audit) {
  try {
    return BusinessBody(raw, length, endpoint, audit);
  } catch (const std::bad_alloc&) {
    return Reject<std::wstring>(Rejection::limit);
  } catch (const std::length_error&) {
    return Reject<std::wstring>(Rejection::limit);
  }
}

void SecureErase(wchar_t* buffer, size_t length) noexcept {
  if (!buffer) return;
  volatile wchar_t* destination = buffer;
  while (length != 0) destination[--length] = L'\0';
}

}  // namespace young_probe
