import Foundation

/// Parses a UUID from a string that may or may not contain hyphens.
/// The server sometimes returns UUIDs as 32-character hex strings without hyphens.
enum FlexibleUUID {
  static func parse(_ string: String) -> UUID? {
    // Standard hyphenated format
    if let uuid = UUID(uuidString: string) {
      return uuid
    }
    // Non-hyphenated 32-char hex: insert hyphens at 8-4-4-4-12 positions
    guard string.count == 32, string.allSatisfy(\.isHexDigit) else { return nil }
    let chars = Array(string)
    let part1 = String(chars[0..<8])
    let part2 = String(chars[8..<12])
    let part3 = String(chars[12..<16])
    let part4 = String(chars[16..<20])
    let part5 = String(chars[20..<32])
    return UUID(uuidString: "\(part1)-\(part2)-\(part3)-\(part4)-\(part5)")
  }
}
