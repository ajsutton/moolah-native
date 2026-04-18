#if os(macOS)
  import SwiftUI

  /// Top-level `Transaction` menu. Operates on the focused window's selected transaction.
  ///
  /// See `guides/STYLE_GUIDE.md` §14 "Transaction" for naming, ordering, and shortcut rationale.
  /// Return and Delete keys fire via the list's native focus handling — they are *not* registered
  /// as menu shortcuts here (doing so would make them fire globally, e.g. while typing in a search
  /// field, which §14 explicitly forbids for destructive actions).
  struct TransactionCommands: Commands {
    @FocusedValue(\.selectedTransaction) private var selectedTransaction

    var body: some Commands {
      CommandMenu("Transaction") {
        Button("Edit Transaction\u{2026}") {
          NotificationCenter.default.post(
            name: .requestTransactionEdit,
            object: selectedTransaction?.wrappedValue?.id
          )
        }
        .disabled(selectedTransaction?.wrappedValue == nil)

        // Duplicate Transaction: shown but permanently disabled until
        // `TransactionStore.duplicate(id:)` is implemented. No keyboard shortcut
        // yet — attaching ⌘D to a disabled item wastes a prime binding silently.
        // Tracked in plans/FEATURE_IDEAS.md.
        Button("Duplicate Transaction") {}
          .disabled(true)

        Divider()

        Button("Delete Transaction\u{2026}", role: .destructive) {
          NotificationCenter.default.post(
            name: .requestTransactionDelete,
            object: selectedTransaction?.wrappedValue?.id
          )
        }
        .disabled(selectedTransaction?.wrappedValue == nil)
      }
    }
  }
#endif
