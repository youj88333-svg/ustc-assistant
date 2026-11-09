import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin

enum IOSAgentImagePolicyFailure: Error {
  case imageRejected
  case resourceLimit
}

/// Converts one PHPicker provider file to the existing Agent PNG contract.
/// The provider URL is consumed in its callback and is never retained.
enum IOSAgentImagePolicy {
  static let maximumOriginalBytes = 10 * 1024 * 1024
  static let maximumPixels = 16_000_000
  static let maximumLongSide = 1536
  static let maximumNormalizedBytes = 3 * 1024 * 1024

  private static let acceptedTypes: Set<String> = [
    UTType.heic.identifier,
    UTType.heif.identifier,
    UTType.jpeg.identifier,
    UTType.png.identifier,
    "org.webmproject.webp",
  ]

  static func normalize(fileAt url: URL) throws -> Data {
    let owned = try normalizeOwned(fileAt: url)
    defer { owned.resetBytes(in: NSRange(location: 0, length: owned.length)) }
    // The standalone policy harness receives its own immutable copy. The
    // picker bridge instead keeps the mutable owner until message encoding.
    return Data(bytes: owned.bytes, count: owned.length)
  }

  static func normalizeOwned(fileAt url: URL) throws -> NSMutableData {
    guard url.isFileURL else { throw IOSAgentImagePolicyFailure.imageRejected }
    // The provider's URL lasts only through its completion callback. Pin a
    // no-follow regular-file descriptor and cap actual reads, not only a prior
    // pathname size check. No original is copied to an app-owned file.
    let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw IOSAgentImagePolicyFailure.imageRejected }
    defer { _ = Darwin.close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0,
          info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size > 0 else {
      throw IOSAgentImagePolicyFailure.imageRejected
    }
    guard info.st_size <= off_t(maximumOriginalBytes) else { throw IOSAgentImagePolicyFailure.resourceLimit }
    var original = Data()
    original.reserveCapacity(Int(info.st_size))
    defer { original.resetBytes(in: 0..<original.count) }
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    defer { _ = chunk.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
    while true {
      let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR { continue }
        throw IOSAgentImagePolicyFailure.imageRejected
      }
      if count == 0 { break }
      guard count <= maximumOriginalBytes - original.count else { throw IOSAgentImagePolicyFailure.resourceLimit }
      original.append(contentsOf: chunk.prefix(count))
    }
    guard original.count == Int(info.st_size) else { throw IOSAgentImagePolicyFailure.imageRejected }

    let sourceOptions = [
      kCGImageSourceShouldCache: false,
    ] as CFDictionary
    guard let source = CGImageSourceCreateWithData(original as CFData, sourceOptions),
          let sourceType = CGImageSourceGetType(source) as String?,
          acceptedTypes.contains(sourceType) else {
      throw IOSAgentImagePolicyFailure.imageRejected
    }
    guard CGImageSourceGetCount(source) == 1,
          let rawProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil),
          let properties = rawProperties as? [CFString: Any],
          let width = positiveInteger(properties[kCGImagePropertyPixelWidth]),
          let height = positiveInteger(properties[kCGImagePropertyPixelHeight]) else {
      throw IOSAgentImagePolicyFailure.imageRejected
    }
    guard width <= maximumPixels / height else {
      throw IOSAgentImagePolicyFailure.resourceLimit
    }
    guard CGImageSourceGetStatus(source) == .statusComplete else {
      throw IOSAgentImagePolicyFailure.imageRejected
    }

    let thumbnailOptions = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumLongSide,
      kCGImageSourceShouldCache: false,
      kCGImageSourceShouldCacheImmediately: true,
    ] as CFDictionary
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
      source, 0, thumbnailOptions
    ) else {
      throw IOSAgentImagePolicyFailure.imageRejected
    }
    let outputWidth = thumbnail.width
    let outputHeight = thumbnail.height
    guard outputWidth > 0, outputHeight > 0,
          outputWidth <= maximumLongSide, outputHeight <= maximumLongSide else {
      throw IOSAgentImagePolicyFailure.imageRejected
    }

    // Render into a new, fixed sRGB bitmap. No source profile, auxiliary data
    // or property dictionary belongs to the new pixel image.
    let rowBytes = outputWidth * 4
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let bitmap = CGContext(data: nil, width: outputWidth, height: outputHeight,
            bitsPerComponent: 8, bytesPerRow: rowBytes, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
      throw IOSAgentImagePolicyFailure.imageRejected
    }
    defer { if let pixels = bitmap.data { memset(pixels, 0, rowBytes * outputHeight) } }
    bitmap.draw(thumbnail, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
    guard let pixelImage = bitmap.makeImage() else {
      throw IOSAgentImagePolicyFailure.imageRejected
    }

    let encoded = NSMutableData()
    defer { encoded.resetBytes(in: NSRange(location: 0, length: encoded.length)) }
    guard let destination = CGImageDestinationCreateWithData(
      encoded, UTType.png.identifier as CFString, 1, nil
    ) else {
      throw IOSAgentImagePolicyFailure.imageRejected
    }
    // Do not copy source property dictionaries: that would retain EXIF/GPS,
    // timestamps, camera identifiers, and other source metadata.
    CGImageDestinationAddImage(destination, pixelImage, nil)
    guard CGImageDestinationFinalize(destination) else {
      encoded.resetBytes(in: NSRange(location: 0, length: encoded.length))
      throw IOSAgentImagePolicyFailure.imageRejected
    }
    guard encoded.length > 0,
          encoded.length <= maximumNormalizedBytes else {
      encoded.resetBytes(in: NSRange(location: 0, length: encoded.length))
      throw IOSAgentImagePolicyFailure.resourceLimit
    }
    return try canonicalEncoderPNG(encoded)
  }

  /// Inspect only this function's own ImageIO PNG, never an arbitrary source.
  /// Some ImageIO encoders synthesize EXIF even with nil properties. Keep only
  /// decoding chunks and color information from the fixed sRGB bitmap, so
  /// personal/text/EXIF/time chunks cannot cross the byte channel.
  private static func canonicalEncoderPNG(_ encoded: NSMutableData) throws -> NSMutableData {
    let bytes = UnsafeBufferPointer(start: encoded.bytes.assumingMemoryBound(to: UInt8.self), count: encoded.length)
    let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    guard bytes.count >= 8, Array(bytes.prefix(8)) == signature else {
      throw IOSAgentImagePolicyFailure.imageRejected
    }
    let kept = NSMutableData()
    var transferred = false
    defer { if !transferred { kept.resetBytes(in: NSRange(location: 0, length: kept.length)) } }
    kept.append(encoded.bytes, length: 8)
    var offset = 8
    var hasHeader = false
    var hasPixels = false
    var ended = false
    while offset <= bytes.count - 12 {
      let size = (0..<4).reduce(0) { ($0 << 8) | Int(bytes[offset + $1]) }
      guard size <= bytes.count - offset - 12,
            let type = String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii) else {
        throw IOSAgentImagePolicyFailure.imageRejected
      }
      if !hasHeader && type != "IHDR" { throw IOSAgentImagePolicyFailure.imageRejected }
      switch type {
      case "IHDR":
        guard !hasHeader, size == 13, offset == 8 else { throw IOSAgentImagePolicyFailure.imageRejected }
        hasHeader = true
      case "IDAT": hasPixels = true
      case "IEND":
        guard hasPixels, size == 0, offset + 12 == bytes.count else { throw IOSAgentImagePolicyFailure.imageRejected }
        ended = true
      case "PLTE", "tRNS", "sRGB", "iCCP", "gAMA", "cHRM":
        guard !hasPixels else { throw IOSAgentImagePolicyFailure.imageRejected }
      default:
        // W3C PNG: unknown critical chunks cannot be ignored. Ancillary
        // chunks outside the closed output set are deliberately discarded.
        guard bytes[offset + 4] & 0x20 != 0 else { throw IOSAgentImagePolicyFailure.imageRejected }
      }
      if ["IHDR", "IDAT", "IEND", "PLTE", "tRNS", "sRGB", "iCCP", "gAMA", "cHRM"].contains(type) {
        kept.append(encoded.bytes.advanced(by: offset), length: size + 12)
      }
      offset += size + 12
    }
    guard hasHeader, hasPixels, ended, offset == bytes.count,
          kept.length <= maximumNormalizedBytes else {
      kept.resetBytes(in: NSRange(location: 0, length: kept.length))
      throw IOSAgentImagePolicyFailure.imageRejected
    }
    transferred = true
    return kept
  }

  private static func positiveInteger(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber else { return nil }
    let double = number.doubleValue
    guard double.isFinite, double > 0,
          double.rounded(.towardZero) == double,
          double <= Double(Int.max) else { return nil }
    return Int(double)
  }
}
