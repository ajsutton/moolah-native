#if os(macOS)
  import SwiftUI

  struct GoCommands: Commands {
    @FocusedValue(\.sidebarSelection) private var sidebarSelection

    var body: some Commands {
      CommandMenu("Go") {
        Button("Transactions") {
          sidebarSelection?.wrappedValue = .allTransactions
        }
        .keyboardShortcut("1", modifiers: .command)
        .disabled(sidebarSelection == nil)
      }
    }
  }
#endif
