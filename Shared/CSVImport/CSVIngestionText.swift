import Foundation

/// Bytes-to-text decoding for CSV ingestion. Uses Apple's built-in encoding
/// detection via `NSString.stringEncoding(for:...)` after a UTF-8 fast path.
enum CSVIngestionText: Sendable {

  enum DecodeError: Error, Equatable {
    case undecodable
  }

  /// Decode bytes to a Swift string. Tries UTF-8 first (covers >99% of bank
  /// exports), then delegates to Apple's encoding detection.
  static func decode(_ data: Data) throws -> String {
    if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
    var converted: NSString?
    let encoding = NSString.stringEncoding(
      for: data,
      encodingOptions: nil,
      convertedString: &converted,
      usedLossyConversion: nil)
    if encoding != 0, let converted {
      return converted as String
    }
    throw DecodeError.undecodable
  }
}
