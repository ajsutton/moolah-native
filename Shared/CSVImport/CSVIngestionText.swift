import Foundation

/// Bytes-to-text decoding for CSV ingestion. Uses a short cascade:
///   UTF-8 fast path  →  UTF-16 when a BOM is present  →  Apple's
///   `NSString.stringEncoding(for:...)` with Windows-1252 hinted  →  a
///   final explicit Windows-1252 decode.
///
/// The explicit CP1252 fallback is intentional: bank exports still ship in
/// Windows-1252 and Apple's detector has been observed to pick ISO/Arabic/
/// Cyrillic over CP1252 for bytes that could plausibly belong to any of
/// them (e.g., 0xC9 is `É` in CP1252 and `ة` in CP1256). Biasing the detector
/// with `suggestedEncodingsKey` and backstopping with CP1252 gives the right
/// answer on all the fixtures we've observed without breaking UTF-16.
enum CSVIngestionText: Sendable {

  enum DecodeError: Error, Equatable {
    case undecodable
  }

  static func decode(_ data: Data) throws -> String {
    if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
    if hasUTF16BOM(data), let s = String(data: data, encoding: .utf16) {
      return s
    }
    var converted: NSString?
    let detected = NSString.stringEncoding(
      for: data,
      encodingOptions: [
        StringEncodingDetectionOptionsKey.suggestedEncodingsKey:
          [String.Encoding.utf8.rawValue, String.Encoding.windowsCP1252.rawValue]
      ],
      convertedString: &converted,
      usedLossyConversion: nil)
    if detected != 0, let converted {
      return converted as String
    }
    if let cp1252 = String(data: data, encoding: .windowsCP1252) {
      return cp1252
    }
    throw DecodeError.undecodable
  }

  private static func hasUTF16BOM(_ data: Data) -> Bool {
    guard data.count >= 2 else { return false }
    let b0 = data[data.startIndex]
    let b1 = data[data.index(after: data.startIndex)]
    return (b0 == 0xFE && b1 == 0xFF) || (b0 == 0xFF && b1 == 0xFE)
  }
}
