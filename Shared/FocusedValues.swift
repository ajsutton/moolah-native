import SwiftUI

/// Trigger action for creating a new transaction (File > New Transaction, ⌘N).
struct NewTransactionActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Trigger action for creating a new earmark (File > New Earmark, ⇧⌘N).
struct NewEarmarkActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Trigger action for creating a new account (File > New Account, ⌃⌘N).
struct NewAccountActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Trigger action for creating a new category (File > New Category, ⌥⌘N).
struct NewCategoryActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Trigger action for refreshing the focused window's data (⌘R).
struct RefreshActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Trigger action for focusing the search field in the active list (⌘F).
struct FindInListActionKey: FocusedValueKey {
  typealias Value = () -> Void
}

/// Binding to the View > Show Hidden Accounts toggle.
struct ShowHiddenAccountsKey: FocusedValueKey {
  typealias Value = Binding<Bool>
}

/// The transaction currently selected in the focused window (for Transaction menu).
struct SelectedTransactionKey: FocusedValueKey {
  typealias Value = Binding<Transaction?>
}

/// The account currently selected in the focused window (for Account menu items).
struct SelectedAccountKey: FocusedValueKey {
  typealias Value = Binding<Account?>
}

/// The earmark currently selected in the focused window (for Earmark menu items).
struct SelectedEarmarkKey: FocusedValueKey {
  typealias Value = Binding<Earmark?>
}

/// The category currently selected in the focused window (for Category menu items).
struct SelectedCategoryKey: FocusedValueKey {
  typealias Value = Binding<Category?>
}

/// Binding to the sidebar destination (for Go menu ⌘1…⌘9).
struct SidebarSelectionKey: FocusedValueKey {
  typealias Value = Binding<SidebarSelection?>
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
  var newAccountAction: NewAccountActionKey.Value? {
    get { self[NewAccountActionKey.self] }
    set { self[NewAccountActionKey.self] = newValue }
  }
  var newCategoryAction: NewCategoryActionKey.Value? {
    get { self[NewCategoryActionKey.self] }
    set { self[NewCategoryActionKey.self] = newValue }
  }
  var refreshAction: RefreshActionKey.Value? {
    get { self[RefreshActionKey.self] }
    set { self[RefreshActionKey.self] = newValue }
  }
  var findInListAction: FindInListActionKey.Value? {
    get { self[FindInListActionKey.self] }
    set { self[FindInListActionKey.self] = newValue }
  }
  var showHiddenAccounts: ShowHiddenAccountsKey.Value? {
    get { self[ShowHiddenAccountsKey.self] }
    set { self[ShowHiddenAccountsKey.self] = newValue }
  }
  var selectedTransaction: SelectedTransactionKey.Value? {
    get { self[SelectedTransactionKey.self] }
    set { self[SelectedTransactionKey.self] = newValue }
  }
  var selectedAccount: SelectedAccountKey.Value? {
    get { self[SelectedAccountKey.self] }
    set { self[SelectedAccountKey.self] = newValue }
  }
  var selectedEarmark: SelectedEarmarkKey.Value? {
    get { self[SelectedEarmarkKey.self] }
    set { self[SelectedEarmarkKey.self] = newValue }
  }
  var selectedCategory: SelectedCategoryKey.Value? {
    get { self[SelectedCategoryKey.self] }
    set { self[SelectedCategoryKey.self] = newValue }
  }
  var sidebarSelection: SidebarSelectionKey.Value? {
    get { self[SidebarSelectionKey.self] }
    set { self[SidebarSelectionKey.self] = newValue }
  }
}
