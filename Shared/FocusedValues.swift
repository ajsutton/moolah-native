import SwiftUI

/// Focused value key for the new transaction action
struct NewTransactionActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Focused value key for the new earmark action
struct NewEarmarkActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Focused value key for the refresh action
struct RefreshActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Focused value key for the show hidden accounts binding
struct ShowHiddenAccountsKey: FocusedValueKey {
  typealias Value = Binding<Bool>
}

extension FocusedValues {
  var newTransactionAction: NewTransactionActionKey.Value? {
    get { self[NewTransactionActionKey.self] }
    set { self[NewTransactionActionKey.self] = newValue }
  }

  var newEarmarkAction: NewEarmarkActionKey.Value? {
    get { self[NewEarmarkActionKey.self] }
    set { self[NewEarmarkActionKey.self] = newValue }
  }

  var refreshAction: RefreshActionKey.Value? {
    get { self[RefreshActionKey.self] }
    set { self[RefreshActionKey.self] = newValue }
  }

  var showHiddenAccounts: ShowHiddenAccountsKey.Value? {
    get { self[ShowHiddenAccountsKey.self] }
    set { self[ShowHiddenAccountsKey.self] = newValue }
  }
}
