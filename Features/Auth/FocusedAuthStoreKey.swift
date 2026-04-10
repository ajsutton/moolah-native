import SwiftUI

/// Allows the focused window's AuthStore to be accessed from Commands.
/// Each macOS profile window publishes its AuthStore via `.focusedValue(\.authStore, ...)`.
struct FocusedAuthStoreKey: FocusedValueKey {
  typealias Value = AuthStore
}

extension FocusedValues {
  var authStore: AuthStore? {
    get { self[FocusedAuthStoreKey.self] }
    set { self[FocusedAuthStoreKey.self] = newValue }
  }
}
