import SwiftUI

/// A navigation request queued from outside the scene graph — typically by an
/// AppleScript `NavigateCommand` or an App Intent — to be consumed by the
/// active `ContentView` on the next render.
struct PendingNavigation: Equatable {
  let profileId: UUID
  let destination: NavigationDestination
}

// MARK: - Environment Key

private struct PendingNavigationKey: EnvironmentKey {
  static let defaultValue: Binding<PendingNavigation?>? = nil
}

extension EnvironmentValues {
  var pendingNavigation: Binding<PendingNavigation?>? {
    get { self[PendingNavigationKey.self] }
    set { self[PendingNavigationKey.self] = newValue }
  }
}
