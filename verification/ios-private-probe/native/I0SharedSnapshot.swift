import CoreFoundation
import CryptoKit
import Foundation

struct I0SharedSnapshot {
  struct Result {
    let groupAvailable: Bool
    let groupDigest: String?
    let marker: String?
    let markerCreatedAt: String?
    let failure: String?
  }

  private struct SharedContainer {
    let url: URL
    let digest: String
  }

  private static let groupBaseIdentifier = "group.cn.ustcassistant.ios.i0"
  private static let groupBaseInfoKey = "I0AppGroupBaseIdentifier"
  private static let alternativeGroupsInfoKey = "ALTAppGroups"
  private static let snapshotFileName = "ios-i0-marker-v1.json"
  private static let maximumSnapshotBytes = 2_048
  private static let maximumAlternativeGroupCandidates = 8
  private static let snapshotKeys: Set<String> = ["version", "marker", "createdAt"]
  private static let markerPattern = try! NSRegularExpression(pattern: #"^i0-[0-9A-Fa-f]{8}$"#)
  private static let teamSuffixPattern = try! NSRegularExpression(pattern: #"^[A-Z0-9]{10}$"#)
  private static let timestampPattern = try! NSRegularExpression(
    pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#
  )

  static func inspect(bundle: Bundle = .main) -> Result {
    let resolved = resolveContainer(bundle: bundle)
    guard let container = resolved.container else {
      return Result(
        groupAvailable: false,
        groupDigest: nil,
        marker: nil,
        markerCreatedAt: nil,
        failure: resolved.failure ?? "shared_group_unavailable"
      )
    }

    let fileURL = container.url.appendingPathComponent(snapshotFileName, isDirectory: false)
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular else {
        return failed(container, "snapshot_invalid")
      }
      if let size = attributes[.size] as? NSNumber, size.intValue > maximumSnapshotBytes {
        return failed(container, "snapshot_too_large")
      }

      let handle = try FileHandle(forReadingFrom: fileURL)
      defer { try? handle.close() }
      let data = try handle.read(upToCount: maximumSnapshotBytes + 1) ?? Data()
      guard data.count <= maximumSnapshotBytes else {
        return failed(container, "snapshot_too_large")
      }
      guard !data.isEmpty,
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
        Set(object.keys) == snapshotKeys,
        isVersionOne(object["version"]),
        let marker = object["marker"] as? String,
        matches(marker, pattern: markerPattern),
        let createdAt = object["createdAt"] as? String,
        isCanonicalUtcTimestamp(createdAt)
      else {
        return failed(container, "snapshot_invalid")
      }

      return Result(
        groupAvailable: true,
        groupDigest: container.digest,
        marker: marker,
        markerCreatedAt: createdAt,
        failure: nil
      )
    } catch {
      if isMissingFileError(error) {
        return failed(container, "snapshot_missing")
      }
      return failed(container, "snapshot_read_failed")
    }
  }

  static func writeSyntheticMarker(bundle: Bundle = .main) -> Result {
    let resolved = resolveContainer(bundle: bundle)
    guard let container = resolved.container else {
      return Result(
        groupAvailable: false,
        groupDigest: nil,
        marker: nil,
        markerCreatedAt: nil,
        failure: resolved.failure ?? "shared_group_unavailable"
      )
    }

    let marker = String(format: "i0-%08x", UInt32.random(in: UInt32.min...UInt32.max))
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let createdAt = formatter.string(from: Date())
    let object: [String: Any] = ["version": 1, "marker": marker, "createdAt": createdAt]
    let fileURL = container.url.appendingPathComponent(snapshotFileName, isDirectory: false)

    do {
      let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      guard data.count <= maximumSnapshotBytes else {
        return failed(container, "snapshot_write_failed")
      }
      try data.write(
        to: fileURL,
        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
      )
    } catch {
      return failed(container, "snapshot_write_failed")
    }

    let readback = inspect(bundle: bundle)
    guard readback.groupAvailable,
      readback.failure == nil,
      readback.marker == marker,
      readback.markerCreatedAt == createdAt
    else {
      let failure = readback.failure ?? "snapshot_readback_mismatch"
      return Result(
        groupAvailable: readback.groupAvailable,
        groupDigest: readback.groupDigest,
        marker: nil,
        markerCreatedAt: nil,
        failure: failure
      )
    }
    return readback
  }

  private static func resolveContainer(bundle: Bundle) -> (container: SharedContainer?, failure: String?) {
    guard bundle.object(forInfoDictionaryKey: groupBaseInfoKey) as? String == groupBaseIdentifier else {
      return (nil, "shared_group_configuration_invalid")
    }

    let identifiers = candidateGroupIdentifiers(bundle: bundle)
    for identifier in identifiers {
      guard let url = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: identifier
      ) else {
        continue
      }
      return (SharedContainer(url: url, digest: shortDigest(identifier)), nil)
    }
    return (nil, "shared_group_unavailable")
  }

  private static func candidateGroupIdentifiers(bundle: Bundle) -> [String] {
    var candidates = [groupBaseIdentifier]
    if let alternatives = bundle.object(forInfoDictionaryKey: alternativeGroupsInfoKey) as? [String] {
      var acceptedAlternatives = 0
      for candidate in alternatives.prefix(64) where isPermittedAlternative(candidate) {
        candidates.append(candidate)
        acceptedAlternatives += 1
        if acceptedAlternatives == maximumAlternativeGroupCandidates { break }
      }
    }
    if let teamSuffix = bundle.bundleIdentifier?.split(separator: ".").last.map(String.init),
      matches(teamSuffix, pattern: teamSuffixPattern)
    {
      candidates.append("\(groupBaseIdentifier).\(teamSuffix)")
    }

    var seen = Set<String>()
    return candidates.filter { seen.insert($0).inserted }
  }

  private static func isPermittedAlternative(_ identifier: String) -> Bool {
    if identifier == groupBaseIdentifier { return true }
    let prefix = "\(groupBaseIdentifier)."
    guard identifier.hasPrefix(prefix) else { return false }
    let suffix = String(identifier.dropFirst(prefix.count))
    return matches(suffix, pattern: teamSuffixPattern)
  }

  private static func isVersionOne(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue == 1
    else {
      return false
    }
    return true
  }

  private static func matches(_ value: String, pattern: NSRegularExpression) -> Bool {
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return pattern.firstMatch(in: value, range: range)?.range == range
  }

  private static func isCanonicalUtcTimestamp(_ value: String) -> Bool {
    guard matches(value, pattern: timestampPattern) else { return false }
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) != nil
  }

  private static func shortDigest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
      .prefix(6)
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static func failed(_ container: SharedContainer, _ failure: String) -> Result {
    Result(
      groupAvailable: true,
      groupDigest: container.digest,
      marker: nil,
      markerCreatedAt: nil,
      failure: failure
    )
  }

  private static func isMissingFileError(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == NSCocoaErrorDomain
      && (nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError)
  }
}
