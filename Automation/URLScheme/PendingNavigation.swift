import SwiftUI

/// Represents a pending navigation request from a URL scheme.
struct PendingNavigation: Equatable {
  let profileId: UUID
  let destination: URLSchemeHandler.Destination
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
