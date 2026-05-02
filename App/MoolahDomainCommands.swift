import SwiftUI

// Command-menu definitions extracted from `MoolahApp.swift` so the app file
// stays under SwiftLint's `file_length` threshold. Each struct remains a
// top-level `Commands` type, preserving its role in `MoolahApp.body`'s
// `.commands { ... }` builder.

/// Combined File > New… commands (Transaction, Earmark, Account, Category).
/// Grouping them into one Commands struct keeps the top-level `.commands` block
/// under `CommandsBuilder`'s 10-argument limit.
struct NewItemCommands: Commands {
  @FocusedValue(\.newTransactionAction) private var newTransactionAction
  @FocusedValue(\.newEarmarkAction) private var newEarmarkAction
  @FocusedValue(\.newAccountAction) private var newAccountAction
  @FocusedValue(\.newCategoryAction) private var newCategoryAction

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Transaction\u{2026}") {
        newTransactionAction?()
      }
      .keyboardShortcut("n", modifiers: .command)
      .disabled(newTransactionAction == nil)

      Button("New Earmark\u{2026}") {
        newEarmarkAction?()
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])
      .disabled(newEarmarkAction == nil)

      Button("New Account\u{2026}") {
        newAccountAction?()
      }
      .keyboardShortcut("n", modifiers: [.command, .control])
      .disabled(newAccountAction == nil)

      Button("New Category\u{2026}") {
        newCategoryAction?()
      }
      .keyboardShortcut("n", modifiers: [.command, .option])
      .disabled(newCategoryAction == nil)
    }
  }
}

/// Commands for refreshing data
struct RefreshCommands: Commands {
  @FocusedValue(\.refreshAction) private var refreshAction

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Divider()
      Button("Refresh") {
        refreshAction?()
      }
      .keyboardShortcut("r", modifiers: .command)
      .disabled(refreshAction == nil)
    }
  }
}

/// View menu verb-pair for showing / hiding hidden accounts and earmarks.
/// Uses a Button with a flipped label (per §14 "Toggle State") and stays
/// visible when no window is focused — disabled per §14 "Disable, don't hide".
struct ShowHiddenCommands: Commands {
  @FocusedValue(\.showHiddenAccounts) private var showHidden

  var body: some Commands {
    CommandGroup(after: .sidebar) {
      Button(
        showHidden?.wrappedValue == true ? "Hide Hidden Accounts" : "Show Hidden Accounts"
      ) {
        showHidden?.wrappedValue.toggle()
      }
      .keyboardShortcut("h", modifiers: [.command, .shift])
      .disabled(showHidden == nil)
    }
  }
}

/// Moolah-specific top-level domain menus grouped into one Commands struct so
/// the outer `.commands` block stays within `CommandsBuilder`'s 10-argument limit.
/// CommandMenus are inlined here (rather than references to per-feature structs)
/// to keep the opaque `some Commands` return type inferable.
struct MoolahDomainCommands: Commands {
  @FocusedValue(\.selectedTransaction) private var selectedTransaction
  @FocusedValue(\.selectedAccount) private var selectedAccount
  @FocusedValue(\.selectedEarmark) private var selectedEarmark
  @FocusedValue(\.selectedCategory) private var selectedCategory
  @FocusedValue(\.sidebarSelection) private var sidebarSelection
  @FocusedValue(\.goBackAction) private var goBackAction
  @FocusedValue(\.goForwardAction) private var goForwardAction
  @FocusedValue(\.findInListAction) private var findInListAction
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openURL) private var openURL

  var body: some Commands {
    CommandMenu("Transaction") {
      Button("Edit Transaction\u{2026}") {
        NotificationCenter.default.post(
          name: .requestTransactionEdit,
          object: selectedTransaction?.wrappedValue?.id
        )
      }
      .disabled(selectedTransaction?.wrappedValue == nil)

      Button("Duplicate Transaction") {}.disabled(true)

      Button("Pay Scheduled Transaction") {
        NotificationCenter.default.post(
          name: .requestTransactionPay,
          object: selectedTransaction?.wrappedValue?.id
        )
      }
      .disabled(selectedTransaction?.wrappedValue?.recurPeriod == nil)

      Divider()

      Button("Delete Transaction\u{2026}", role: .destructive) {
        NotificationCenter.default.post(
          name: .requestTransactionDelete,
          object: selectedTransaction?.wrappedValue?.id
        )
      }
      .disabled(selectedTransaction?.wrappedValue == nil)
    }

    CommandMenu("Go") {
      goMenuItems
    }

    CommandMenu("Account") {
      Button("Edit Account\u{2026}") {
        NotificationCenter.default.post(
          name: .requestAccountEdit,
          object: selectedAccount?.wrappedValue?.id
        )
      }
      .disabled(selectedAccount?.wrappedValue == nil)

      Button("View Transactions") {
        if let id = selectedAccount?.wrappedValue?.id {
          sidebarSelection?.wrappedValue = .account(id)
        }
      }
      .disabled(selectedAccount?.wrappedValue == nil)
    }

    CommandMenu("Earmark") {
      Button("Edit Earmark\u{2026}") {
        NotificationCenter.default.post(
          name: .requestEarmarkEdit,
          object: selectedEarmark?.wrappedValue?.id
        )
      }
      .disabled(selectedEarmark?.wrappedValue == nil)

      Button(
        selectedEarmark?.wrappedValue?.isHidden == true ? "Show Earmark" : "Hide Earmark"
      ) {
        NotificationCenter.default.post(
          name: .requestEarmarkToggleHidden,
          object: selectedEarmark?.wrappedValue?.id
        )
      }
      .disabled(selectedEarmark?.wrappedValue == nil)
    }

    CommandMenu("Category") {
      Button("Edit Category\u{2026}") {
        NotificationCenter.default.post(
          name: .requestCategoryEdit,
          object: selectedCategory?.wrappedValue?.id
        )
      }
      .disabled(selectedCategory?.wrappedValue == nil)
    }

    CommandGroup(after: .textEditing) {
      Button("Find Transactions\u{2026}") { findInListAction?() }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(findInListAction == nil)

      Button("Find Next") {}
        .keyboardShortcut("g", modifiers: .command)
        .disabled(true)

      Button("Find Previous") {}
        .keyboardShortcut("g", modifiers: [.command, .shift])
        .disabled(true)
    }

    CommandGroup(after: .pasteboard) {
      Button("Copy Transaction Link") {}
        .keyboardShortcut("c", modifiers: [.command, .control])
        .disabled(true)
    }

    CommandGroup(after: .help) {
      Button("Moolah Help") {
        if let url = URL(string: "https://moolah.app/help") { openURL(url) }
      }

      Button("Keyboard Shortcuts\u{2026}") {
        openWindow(id: "keyboard-shortcuts")
      }
      .keyboardShortcut("/", modifiers: [.command, .shift])

      Divider()

      Button("Release Notes") {
        if let url = URL(string: "https://moolah.app/release-notes") { openURL(url) }
      }

      Button("Report a Bug") {
        if let url = URL(string: "https://github.com/ajsutton/moolah-native/issues/new") {
          openURL(url)
        }
      }

      Divider()

      Button("Privacy Policy") {
        if let url = URL(string: "https://moolah.app/privacy") { openURL(url) }
      }

      Button("Terms of Service") {
        if let url = URL(string: "https://moolah.app/terms") { openURL(url) }
      }
    }
  }

  @ViewBuilder private var goMenuItems: some View {
    // Back/Forward at the top of the Go menu, matching macOS HIG / Safari /
    // Xcode / Finder / Mail. Numbered destinations follow.
    Button("Go Back") { goBackAction?() }
      .keyboardShortcut("[", modifiers: .command)
      .disabled(goBackAction == nil)
    Button("Go Forward") { goForwardAction?() }
      .keyboardShortcut("]", modifiers: .command)
      .disabled(goForwardAction == nil)
    Divider()
    Button("Transactions") { sidebarSelection?.wrappedValue = .allTransactions }
      .keyboardShortcut("1", modifiers: .command)
      .disabled(sidebarSelection == nil)
    Button("Scheduled") { sidebarSelection?.wrappedValue = .upcomingTransactions }
      .keyboardShortcut("2", modifiers: .command)
      .disabled(sidebarSelection == nil)
    Button("Categories") { sidebarSelection?.wrappedValue = .categories }
      .keyboardShortcut("3", modifiers: .command)
      .disabled(sidebarSelection == nil)
    Button("Reports") { sidebarSelection?.wrappedValue = .reports }
      .keyboardShortcut("4", modifiers: .command)
      .disabled(sidebarSelection == nil)
    Button("Analysis") { sidebarSelection?.wrappedValue = .analysis }
      .keyboardShortcut("5", modifiers: .command)
      .disabled(sidebarSelection == nil)
  }
}
