#if os(macOS)
  import AppKit
  import Foundation

  /// Finds and activates the existing window for a profile without going
  /// through the `moolah://` URL scheme — used by AppleScript and App Intents
  /// to focus an already-open profile without triggering SwiftUI's
  /// `WindowGroup(for:)` auto-spawn on URL events. See issue #378.
  ///
  /// Per-window identifiers are stamped onto the `NSWindow` by
  /// `ProfileWindowView` via `WindowAccessor`.
  enum ProfileWindowLocator {

    /// Stable per-profile identifier; matches the one `ProfileWindowView`
    /// writes to `NSWindow.identifier`.
    static func identifier(for profileID: UUID) -> NSUserInterfaceItemIdentifier {
      NSUserInterfaceItemIdentifier("moolah.profile.\(profileID.uuidString)")
    }

    /// Returns the first window in `windows` whose identifier matches the
    /// given profile. Pure lookup — the side-effecting version is
    /// `activateExistingWindow(for:)`.
    @MainActor
    static func existingWindow(for profileID: UUID, in windows: [NSWindow]) -> NSWindow? {
      let target = identifier(for: profileID)
      return windows.first { $0.identifier == target }
    }

    /// Brings the worktree's existing window for the profile to the front.
    /// Returns `true` if a window was found and activated; `false` if the
    /// caller should open a new window (e.g. via the scene's `openWindow`
    /// action) instead.
    @MainActor
    @discardableResult
    static func activateExistingWindow(for profileID: UUID) -> Bool {
      guard let window = existingWindow(for: profileID, in: NSApp.windows) else {
        return false
      }
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      return true
    }
  }
#endif
