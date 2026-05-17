import CryptoKit
import Foundation

extension UUID {
  /// Returns a UUID derived deterministically from `seed`.
  ///
  /// Built from the first 16 bytes of SHA-256(`seed`), with the version
  /// (nibble 6) and variant (nibble 8) bits forced to RFC-4122 v4 /
  /// variant-1. Identical seeds produce identical UUIDs on every
  /// device, which is what makes idempotent cross-device upserts of
  /// content-addressed records possible. Not a substitute for a random
  /// UUID where unpredictability of attacker-chosen seeds matters.
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
