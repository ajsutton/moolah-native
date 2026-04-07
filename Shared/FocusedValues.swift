import SwiftUI

/// Focused value key for the new transaction action
struct NewTransactionActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var newTransactionAction: NewTransactionActionKey.Value? {
    get { self[NewTransactionActionKey.self] }
    set { self[NewTransactionActionKey.self] = newValue }
  }
}
