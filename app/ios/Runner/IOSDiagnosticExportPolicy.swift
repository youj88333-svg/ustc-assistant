import Foundation
import CoreFoundation

enum IOSDiagnosticExportFailure: String, Error {
  case invalidInput = "invalid_input"
  case exportFailed = "export_failed"
  case closed
}

/// The native side repeats the outer-envelope checks before it creates a file.
/// Dart remains responsible for rebuilding every DiagnosticRecord whitelist.
enum IOSDiagnosticExportPolicy {
  static let maximumBytes = 2 * 1024 * 1024
  static let filename = "USTC-Assistant-diagnostics.json"
  static let kind = "ustc-diagnostics-export-v1"

  private static let fields: Set<String> = [
    "kind", "exportedAtUtc", "retentionDays", "versions", "coverage",
    "selectionTruncated", "complete", "dropped", "invalid", "records"
  ]
  private static let versionFields: Set<String> = [
    "application", "schema", "tools", "prompt", "revision"
  ]

  static func canonicalJSON(_ contents: String) throws -> Data {
    let input = Data(contents.utf8)
    guard !input.isEmpty, input.count <= maximumBytes else {
      throw IOSDiagnosticExportFailure.invalidInput
    }

    let parsed: Any
    do {
      parsed = try JSONSerialization.jsonObject(with: input, options: [.fragmentsAllowed])
    } catch {
      throw IOSDiagnosticExportFailure.invalidInput
    }

    guard let object = parsed as? [String: Any],
          Set(object.keys) == fields,
          object["kind"] as? String == kind,
          let exportedAtUtc = object["exportedAtUtc"] as? String,
          exportedAtUtc.count <= 32,
          exportedAtUtc.hasSuffix("Z"),
          integer(object["retentionDays"], equals: 7),
          let coverage = object["coverage"] as? String,
          coverage == "retained_recent_events" || coverage == "startup_error_only",
          isBoolean(object["selectionTruncated"]),
          isBoolean(object["complete"]),
          coverage != "startup_error_only" || (object["complete"] as? Bool) == false,
          integer(object["dropped"]),
          integer(object["invalid"]),
          let versions = object["versions"] as? [String: Any],
          Set(versions.keys) == versionFields,
          versions["application"] as? String != nil,
          versions["tools"] as? String != nil,
          versions["prompt"] as? String != nil,
          versions["revision"] as? String != nil,
          integer(versions["schema"]),
          let records = object["records"] as? [Any],
          records.count <= 1000 else {
      throw IOSDiagnosticExportFailure.invalidInput
    }

    do {
      // Re-encoding prevents duplicate JSON keys or ignored trailing bytes in
      // the received string from being copied into the user-selected file.
      let output = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .fragmentsAllowed]
      )
      guard !output.isEmpty, output.count <= maximumBytes else {
        throw IOSDiagnosticExportFailure.invalidInput
      }
      return output
    } catch let failure as IOSDiagnosticExportFailure {
      throw failure
    } catch {
      throw IOSDiagnosticExportFailure.invalidInput
    }
  }

  private static func isBoolean(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
  }

  private static func integer(_ value: Any?, equals expected: Int? = nil) -> Bool {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
    let double = number.doubleValue
    guard double.isFinite,
          double >= 0,
          double <= 9_007_199_254_740_991,
          double.rounded(.towardZero) == double else { return false }
    return expected.map { double == Double($0) } ?? true
  }
}
