import Foundation

/// Reads the build's user-facing version string from `Info.plist`.
///
/// `AppVersion` is a case-less enum used as a namespace.
/// Single source of truth for `CFBundleShortVersionString` so views never
/// poke at `Bundle.main` directly.
enum AppVersion {
  /// `CFBundleShortVersionString`, or `"?"` if unset (test/preview only).
  static let shortVersionString: String =
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
}
