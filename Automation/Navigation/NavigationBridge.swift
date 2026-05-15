import Foundation

/// Cross-platform bridge from App Intents and AppleScript commands into the
/// running scene graph. Populated by the root profile view
/// (`ProfileWindowView` on macOS, `ProfileRootView` on iOS) as soon as its
/// `.task` runs, so callers can open a profile or set a pending navigation
/// without firing a URL event — which on macOS triggers SwiftUI's
/// `WindowGroup(for:)` auto-spawn (issue #378). The `moolah://` URL
/// scheme does not exist (issue #386), so a URL event cannot be routed
/// back to the app at all.
@MainActor
enum NavigationBridge {
  /// Opens or focuses the window / session for the given profile. On macOS
  /// this calls the scene's `openWindow(value:)` action; on iOS it switches
  /// the `ProfileStore.activeProfileID`.
  static var openProfile: ((UUID) -> Void)?

  /// Enqueues a navigation destination to be consumed by the profile's
  /// `ContentView` on its next render.
  static var setPendingNavigation: ((PendingNavigation) -> Void)?
}
