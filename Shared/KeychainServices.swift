import Foundation

/// Env-scoped keychain service strings. A Development build targets
/// `com.moolah.api-keys.development`; a Production build targets
/// `com.moolah.api-keys.production`. Splitting the service string per
/// CloudKit env stops a Development build from overwriting a Production
/// build's iCloud-Keychain-synced API key on every device.
enum KeychainServices {
  /// Service string for API-key keychain rows (CoinGecko, Alchemy)
  /// scoped to the resolved CloudKit environment. Production code uses
  /// this in place of the previous `"com.moolah.api-keys"` literal.
  static let apiKeys: String = makeApiKeysService(for: .resolved())

  /// Factory used by `apiKeys`. Exposed so tests can verify the
  /// service-string format for both environments without process-level
  /// Info.plist swapping. Mirrors `CloudKitEnvironment.resolve(from:)`
  /// and the `makeSharedSuite(for:)` factory on `UserDefaults`.
  static func makeApiKeysService(for env: CloudKitEnvironment) -> String {
    "com.moolah.api-keys.\(env.storageSubdirectory.lowercased())"
  }
}
