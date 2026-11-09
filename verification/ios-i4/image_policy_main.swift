import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
private struct IOSAgentImagePolicyMain {
  static func main() {
    guard CommandLine.arguments.count == 1 else {
      emit(["kind": "ios-i4-image-policy-self-test-v1", "ok": false,
            "error": "arguments_not_supported"])
      exit(2)
    }

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ios-i4-image-policy-\(ProcessInfo.processInfo.globallyUniqueString)",
                              isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    } catch {
      emit(["kind": "ios-i4-image-policy-self-test-v1", "ok": false,
            "error": "temporary_directory_failed"])
      exit(1)
    }
    defer { try? FileManager.default.removeItem(at: root) }

    var checks: [String: String] = [:]
    func record(_ name: String, _ status: String) { checks[name] = status }
    func run(_ name: String, _ check: () throws -> Bool) {
      do { record(name, try check() ? "pass" : "fail") }
      catch { record(name, "fail") }
    }

    run("static_png") {
      let source = root.appendingPathComponent("static.png")
      try writeImage(makeImage(width: 20, height: 10), to: source,
                     type: UTType.png.identifier)
      let output = try IOSAgentImagePolicy.normalize(fileAt: source)
      return hasSize(output, width: 20, height: 10) && isPNG(output)
    }

    run("jpeg_orientation_and_metadata") {
      let source = root.appendingPathComponent("oriented.jpg")
      let marker = "SYNTHETIC-I4-METADATA-MARKER"
      let metadata: [CFString: Any] = [
        kCGImagePropertyOrientation: 6,
        kCGImagePropertyExifDictionary: [
          kCGImagePropertyExifUserComment: marker,
        ] as [CFString: Any],
        kCGImagePropertyGPSDictionary: [
          kCGImagePropertyGPSLatitude: 12.5,
          kCGImagePropertyGPSLongitude: 25.0,
        ] as [CFString: Any],
      ]
      try writeImage(makeImage(width: 4, height: 2), to: source,
                     type: UTType.jpeg.identifier, properties: metadata)
      let output = try IOSAgentImagePolicy.normalize(fileAt: source)
      guard hasSize(output, width: 2, height: 4),
            let properties = outputProperties(output) else {
        return false
      }
      let markerData = Data(marker.utf8)
      return isPNG(output)
        && properties[kCGImagePropertyExifDictionary] == nil
        && properties[kCGImagePropertyGPSDictionary] == nil
        && properties[kCGImagePropertyTIFFDictionary] == nil
        && output.range(of: markerData) == nil
    }

    run("resize_long_side") {
      let source = root.appendingPathComponent("wide.jpg")
      try writeImage(makeImage(width: 2000, height: 1000), to: source,
                     type: UTType.jpeg.identifier)
      let output = try IOSAgentImagePolicy.normalize(fileAt: source)
      return hasSize(output, width: 1536, height: 768)
    }

    run("sixteen_megapixel_inclusive") {
      let source = root.appendingPathComponent("pixels_16m.jpg")
      try writeImage(makeImage(width: 4000, height: 4000), to: source,
                     type: UTType.jpeg.identifier)
      let output = try IOSAgentImagePolicy.normalize(fileAt: source)
      return hasSize(output, width: 1536, height: 1536)
    }

    run("sixteen_megapixel_plus_one_rejected") {
      let source = root.appendingPathComponent("pixels_over.jpg")
      try writeImage(makeImage(width: 4001, height: 4000), to: source,
                     type: UTType.jpeg.identifier)
      return expectFailure(.resourceLimit) {
        try IOSAgentImagePolicy.normalize(fileAt: source)
      }
    }

    run("ten_mib_source_limit_inclusive") {
      let source = root.appendingPathComponent("bytes_at_limit.jpg")
      try writeImage(makeImage(width: 8, height: 6), to: source,
                     type: UTType.jpeg.identifier)
      let currentSize = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard currentSize > 0,
            currentSize < IOSAgentImagePolicy.maximumOriginalBytes else { return false }
      let padding = Data(repeating: 0, count: IOSAgentImagePolicy.maximumOriginalBytes - currentSize)
      let handle = try FileHandle(forWritingTo: source)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: padding)
      try handle.close()
      let exactSize = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize
      guard exactSize == IOSAgentImagePolicy.maximumOriginalBytes else { return false }
      let output = try IOSAgentImagePolicy.normalize(fileAt: source)
      return hasSize(output, width: 8, height: 6)
    }

    run("source_byte_limit_rejected") {
      let source = root.appendingPathComponent("bytes_over.png")
      let bytes = Data(repeating: 0, count: IOSAgentImagePolicy.maximumOriginalBytes + 1)
      guard FileManager.default.createFile(atPath: source.path, contents: bytes) else {
        return false
      }
      return expectFailure(.resourceLimit) {
        try IOSAgentImagePolicy.normalize(fileAt: source)
      }
    }

    run("normalized_byte_limit_rejected") {
      let source = root.appendingPathComponent("noisy.jpg")
      try writeImage(makeImage(width: 1536, height: 1536, noise: true), to: source,
                     type: UTType.jpeg.identifier, properties: [
                       kCGImageDestinationLossyCompressionQuality: 0.8,
                     ])
      let sourceSize = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard sourceSize <= IOSAgentImagePolicy.maximumOriginalBytes else { return false }
      return expectFailure(.resourceLimit) {
        try IOSAgentImagePolicy.normalize(fileAt: source)
      }
    }

    run("corrupt_input_rejected") {
      let source = root.appendingPathComponent("corrupt.png")
      guard FileManager.default.createFile(atPath: source.path,
                                           contents: Data([1, 2, 3, 4, 5])) else {
        return false
      }
      return expectFailure(.imageRejected) {
        try IOSAgentImagePolicy.normalize(fileAt: source)
      }
    }

    run("symlink_rejected") {
      let target = root.appendingPathComponent("target.png")
      let link = root.appendingPathComponent("link.png")
      try writeImage(makeImage(width: 2, height: 2), to: target,
                     type: UTType.png.identifier)
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
      return expectFailure(.imageRejected) {
        try IOSAgentImagePolicy.normalize(fileAt: link)
      }
    }

    if imageWriterAvailable(UTType.heic.identifier) {
      run("heic_current_representation") {
        let source = root.appendingPathComponent("still.heic")
        try writeImage(makeImage(width: 12, height: 8), to: source,
                       type: UTType.heic.identifier)
        let output = try IOSAgentImagePolicy.normalize(fileAt: source)
        return hasSize(output, width: 12, height: 8) && isPNG(output)
      }
    } else {
      record("heic_current_representation", "unsupported")
    }

    let webpIdentifier = "org.webmproject.webp"
    if imageWriterAvailable(webpIdentifier) {
      run("webp_static_if_available") {
        let source = root.appendingPathComponent("still.webp")
        try writeImage(makeImage(width: 12, height: 8), to: source,
                       type: webpIdentifier)
        let output = try IOSAgentImagePolicy.normalize(fileAt: source)
        return hasSize(output, width: 12, height: 8) && isPNG(output)
      }
    } else {
      record("webp_static_if_available", "unsupported")
    }

    if imageWriterAvailable(webpIdentifier) {
      run("animated_webp_rejected_if_available") {
        let source = root.appendingPathComponent("animated.webp")
        try writeAnimatedWebP(to: source, identifier: webpIdentifier)
        return expectFailure(.imageRejected) {
          try IOSAgentImagePolicy.normalize(fileAt: source)
        }
      }
    } else {
      record("animated_webp_rejected_if_available", "unsupported")
    }

    if imageWriterAvailable(UTType.gif.identifier) {
      run("animated_gif_rejected") {
        let source = root.appendingPathComponent("animated.gif")
        try writeAnimatedGIF(to: source)
        return expectFailure(.imageRejected) {
          try IOSAgentImagePolicy.normalize(fileAt: source)
        }
      }
    } else {
      record("animated_gif_rejected", "unsupported")
    }

    let ok = !checks.values.contains("fail")
    emit(["kind": "ios-i4-image-policy-self-test-v1", "ok": ok,
          "checks": checks])
    exit(ok ? 0 : 1)
  }

  private static func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
      print("{\"kind\":\"ios-i4-image-policy-self-test-v1\",\"ok\":false}")
      return
    }
    print(text)
  }

  private static func makeImage(width: Int, height: Int, noise: Bool = false) -> CGImage {
    var pixels = Data(count: width * height * 4)
    pixels.withUnsafeMutableBytes { raw in
      guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
      var state: UInt32 = 0x4914_2026
      for pixel in 0..<(width * height) {
        let offset = pixel * 4
        if noise {
          state = state &* 1_664_525 &+ 1_013_904_223
          bytes[offset] = UInt8(truncatingIfNeeded: state >> 24)
          state = state &* 1_664_525 &+ 1_013_904_223
          bytes[offset + 1] = UInt8(truncatingIfNeeded: state >> 24)
          state = state &* 1_664_525 &+ 1_013_904_223
          bytes[offset + 2] = UInt8(truncatingIfNeeded: state >> 24)
        } else {
          bytes[offset] = 50
          bytes[offset + 1] = 100
          bytes[offset + 2] = 150
        }
        bytes[offset + 3] = 255
      }
    }
    let provider = CGDataProvider(data: pixels as CFData)!
    return CGImage(width: width, height: height,
                   bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: width * 4,
                   space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                     .union(.byteOrder32Big),
                   provider: provider, decode: nil,
                   shouldInterpolate: false, intent: .defaultIntent)!
  }

  private static func writeImage(
    _ image: CGImage,
    to url: URL,
    type: String,
    properties: [CFString: Any] = [:]
  ) throws {
    guard let destination = CGImageDestinationCreateWithURL(
      url as CFURL, type as CFString, 1, nil
    ) else { throw CLIError.syntheticEncode }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw CLIError.syntheticEncode
    }
  }

  private static func writeAnimatedGIF(to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
      url as CFURL, UTType.gif.identifier as CFString, 2, nil
    ) else { throw CLIError.syntheticEncode }
    let frameProperties: [CFString: Any] = [
      kCGImagePropertyGIFDictionary: [
        kCGImagePropertyGIFDelayTime: 0.1,
      ] as [CFString: Any],
    ]
    CGImageDestinationAddImage(destination, makeImage(width: 8, height: 6),
                               frameProperties as CFDictionary)
    CGImageDestinationAddImage(destination, makeImage(width: 8, height: 6, noise: true),
                               frameProperties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw CLIError.syntheticEncode
    }
  }

  private static func writeAnimatedWebP(to url: URL, identifier: String) throws {
    guard let destination = CGImageDestinationCreateWithURL(
      url as CFURL, identifier as CFString, 2, nil
    ) else { throw CLIError.syntheticEncode }
    CGImageDestinationAddImage(destination, makeImage(width: 8, height: 6), nil)
    CGImageDestinationAddImage(destination, makeImage(width: 8, height: 6, noise: true), nil)
    guard CGImageDestinationFinalize(destination) else {
      throw CLIError.syntheticEncode
    }
  }

  private static func outputProperties(_ data: Data) -> [CFString: Any]? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          CGImageSourceGetCount(source) == 1,
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) else {
      return nil
    }
    return properties as? [CFString: Any]
  }

  private static func outputSize(_ data: Data) -> (Int, Int)? {
    guard let properties = outputProperties(data),
          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
      return nil
    }
    return (width.intValue, height.intValue)
  }

  private static func hasSize(_ data: Data, width: Int, height: Int) -> Bool {
    guard let size = outputSize(data) else { return false }
    return size.0 == width && size.1 == height
  }

  private static func isPNG(_ data: Data) -> Bool {
    data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
  }

  private static func imageWriterAvailable(_ identifier: String) -> Bool {
    guard let identifiers = CGImageDestinationCopyTypeIdentifiers() as? [String] else {
      return false
    }
    return identifiers.contains(identifier)
  }

  private static func expectFailure(
    _ expected: IOSAgentImagePolicyFailure,
    action: () throws -> Data
  ) -> Bool {
    do {
      _ = try action()
      return false
    } catch let failure as IOSAgentImagePolicyFailure {
      switch (expected, failure) {
      case (.imageRejected, .imageRejected), (.resourceLimit, .resourceLimit): return true
      default: return false
      }
    } catch {
      return false
    }
  }
}

private enum CLIError: Error { case syntheticEncode }
