import CryptoKit
import Foundation

extension UUID {
  /// A stable UUID derived from `seed` (first 16 bytes of its SHA-256,
  /// RFC-4122 version/variant bits set). Same seed → same UUID on every
  /// device. Used for content-addressed records.
  static func deterministic(from seed: String) -> UUID {
    var digest = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
    digest[6] = (digest[6] & 0x0F) | 0x40
    digest[8] = (digest[8] & 0x3F) | 0x80
    return UUID(
      uuid: (
        digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
        digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
      ))
  }
}
