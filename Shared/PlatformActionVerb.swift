import Foundation

/// Platform-correct action verbs for user-facing copy.
///
/// macOS users click with a pointer; iOS users tap on a touchscreen. Per
/// `guides/STYLE_GUIDE.md` §1 (macOS-First Philosophy) and Apple HIG, prompts
/// must use the platform-appropriate verb. Using "Tap" on macOS (or "Click" on
/// iOS) feels foreign and undermines the native feel of the app.
///
/// Prefer this helper over inline `#if os(macOS)` branches so the convention is
/// centralised and testable.
enum PlatformActionVerb {
  /// The imperative form of the primary input verb for the current platform.
  ///
  /// - macOS, visionOS (pointer/indirect input): `"Click"`
  /// - iOS, iPadOS, watchOS, tvOS, Catalyst (touch-first): `"Tap"`
  static var imperative: String {
    #if os(macOS)
      return "Click"
    #else
      return "Tap"
    #endif
  }

  /// Builds an empty-state prompt of the form
  /// `"<Click|Tap> <buttonLabel> <suffix>"`, e.g. `"Click + to record a value"`.
  ///
  /// Use this for `ContentUnavailableView` descriptions that reference a button
  /// the user should press.
  static func emptyStatePrompt(buttonLabel: String, suffix: String) -> String {
    "\(imperative) \(buttonLabel) \(suffix)"
  }
}
