import SwiftUI

/// Allows the focused window's ProfileSession to be accessed from Commands.
/// Each macOS profile window publishes its ProfileSession via `.focusedValue(\.activeProfileSession, ...)`.
struct FocusedProfileSessionKey: FocusedValueKey {
  typealias Value = ProfileSession
}

extension FocusedValues {
  var activeProfileSession: ProfileSession? {
    get { self[FocusedProfileSessionKey.self] }
    set { self[FocusedProfileSessionKey.self] = newValue }
  }
}
