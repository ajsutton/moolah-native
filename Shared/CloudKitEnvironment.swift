import Foundation

/// The CloudKit environment this build is signed for, as declared in
/// Info.plist. Resolves once at launch and is the single source of truth for
/// any code that must separate on-disk state between Development and
/// Production CloudKit containers.
enum CloudKitEnvironment: String, Sendable {
  case development = "Development"
  case production = "Production"

  /// Name of the subdirectory under Application Support that this environment
  /// writes to. Equal to the raw value.
  var storageSubdirectory: String { rawValue }

  private static let cached: CloudKitEnvironment = {
    resolve(from: Bundle.main.object(forInfoDictionaryKey: Self.infoPlistKey))
  }()

  /// The CloudKit environment the running process is signed for. Resolves
  /// from `Bundle.main`'s `MoolahCloudKitEnvironment` Info.plist key once
  /// per process. Aborts the process via `fatalError` if the key is missing
  /// or does not match a known environment.
  static func resolved() -> CloudKitEnvironment { cached }

  /// Testable form of the resolver. Production code uses `resolved()`.
  static func resolve(from value: Any?) -> CloudKitEnvironment {
    guard let raw = value as? String, let env = CloudKitEnvironment(rawValue: raw) else {
      fatalError(
        """
        \(infoPlistKey) Info.plist key missing or invalid (got: \
        \(String(describing: value))). Expected "Development" or "Production". \
        This build is misconfigured; refusing to start.
        """
      )
    }
    return env
  }

  static let infoPlistKey = "MoolahCloudKitEnvironment"
}
