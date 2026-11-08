import Foundation

@main
struct IOSDiagnosticExportPolicyCheck {
  static func main() throws {
    let valid = document()
    guard let data = try? IOSDiagnosticExportPolicy.canonicalJSON(valid),
          (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
      fatalError("valid diagnostic envelope rejected")
    }

    let invalid = [
      "{",
      valid.replacingOccurrences(of: "ustc-diagnostics-export-v1", with: "unknown"),
      valid.replacingOccurrences(of: "\"complete\":true,", with: ""),
      valid.replacingOccurrences(of: "\"records\":[]", with: "\"records\":[],\"path\":\"/private\"")
    ]
    for value in invalid {
      guard (try? IOSDiagnosticExportPolicy.canonicalJSON(value)) == nil else {
        fatalError("invalid diagnostic envelope accepted")
      }
    }

    let hidden = valid.replacingOccurrences(
      of: "\"records\":[]",
      with: "\"records\":[\"synthetic hidden value\"],\"records\":[]"
    )
    guard let sanitized = try? IOSDiagnosticExportPolicy.canonicalJSON(hidden),
          !String(decoding: sanitized, as: UTF8.self).contains("synthetic hidden value") else {
      fatalError("duplicate-key source text was copied")
    }

    let oversized = document(application: String(repeating: "x", count: IOSDiagnosticExportPolicy.maximumBytes))
    guard (try? IOSDiagnosticExportPolicy.canonicalJSON(oversized)) == nil else {
      fatalError("oversized export accepted")
    }
    print("iOS diagnostic export policy checks passed")
  }

  private static func document(application: String = "unknown") -> String {
    let object: [String: Any] = [
      "kind": "ustc-diagnostics-export-v1",
      "exportedAtUtc": "2026-11-08T00:00:00.000Z",
      "retentionDays": 7,
      "versions": [
        "application": application,
        "schema": 0,
        "tools": "unknown",
        "prompt": "unknown",
        "revision": "unknown"
      ],
      "coverage": "retained_recent_events",
      "selectionTruncated": false,
      "complete": true,
      "dropped": 0,
      "invalid": 0,
      "records": []
    ]
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }
}
