import SwiftUI

/// Transfer-suggestion banner in the transaction detail. Shown when the
/// transaction carries a `transferSuggestion` (fuzzy detection paired it
/// with a likely counterpart on another account). Mirrors the
/// conditional self-hiding pattern of `TransactionDetailBlockExplorerSection`:
/// renders nothing when `transaction.transferSuggestion == nil`.
///
/// Two sections per UI_GUIDE §6/§14: a banner with the affirmative
/// "Merge as Transfer" action, and a separate trailing section carrying
/// the destructive "Not a Transfer" action. The destructive action only
/// arms a confirmation flag; the `.confirmationDialog` itself lives in
/// `TransactionDetailView`'s body (the house pattern — a section button
/// sets a parent `@State` flag, the dialog is attached once at the body
/// level).
///
/// Coordinator access: the merge / dismiss orchestration lives on
/// `TransactionStore` (`mergeSuggestedTransfer` / `dismissSuggestedTransfer`,
/// which resolve the counterpart and delegate to
/// `TransferDetectionCoordinator`). `TransactionStore` is passed into
/// `TransactionDetailView` and on into this section, so the section
/// stays a thin renderer with one-line `Task { … }` dispatches and no
/// `@Environment(ImportStore.self)` dependency (`ImportStore` is
/// import-flow-scoped and is not in the detail view's environment).
struct TransactionDetailTransferSuggestion: View {
  let transaction: Transaction
  let transactionStore: TransactionStore
  /// Bound to the parent's confirmation flag. The destructive button
  /// flips this; `TransactionDetailView` owns the matching dialog.
  @Binding var showDismissConfirmation: Bool

  var body: some View {
    if transaction.transferSuggestion != nil {
      Section {
        // Note: if a monetary amount is ever added to this banner, apply
        // .monospacedDigit() (UI_GUIDE §4).
        Label {
          Text("This looks like a transfer to another account.")
            .foregroundStyle(.secondary)
        } icon: {
          Image(systemName: "arrow.left.arrow.right")
            .foregroundStyle(.blue)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
          "Transfer suggestion: This looks like a transfer to another account."
        )
        .accessibilityIdentifier(
          UITestIdentifiers.TransferDetection.detailBanner(transaction.id))

        Button("Merge as Transfer") {
          Task { await transactionStore.mergeSuggestedTransfer(transaction) }
        }
        .accessibilityIdentifier(
          UITestIdentifiers.TransferDetection.merge(transaction.id))
      }

      Section {
        Button("Not a Transfer", role: .destructive) {
          showDismissConfirmation = true
        }
        .accessibilityIdentifier(
          UITestIdentifiers.TransferDetection.dismiss(transaction.id))
      }
    }
  }
}

#Preview {
  @Previewable @State var showDismissConfirmation = false
  let backend = PreviewBackend.create()
  let store = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  let transaction = Transaction(
    date: Date(),
    payee: "Transfer to Savings",
    legs: [
      TransactionLeg(
        accountId: UUID(), instrument: .AUD, quantity: -500, type: .expense)
    ],
    transferSuggestion: TransferSuggestion(
      counterpartTransactionId: UUID(), suggestedAt: Date()))
  return Form {
    TransactionDetailTransferSuggestion(
      transaction: transaction,
      transactionStore: store,
      showDismissConfirmation: $showDismissConfirmation)
  }
  .formStyle(.grouped)
}

#Preview("No suggestion (hidden)") {
  @Previewable @State var showDismissConfirmation = false
  let backend = PreviewBackend.create()
  let store = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  let transaction = Transaction(
    date: Date(),
    payee: "Groceries",
    legs: [
      TransactionLeg(
        accountId: UUID(), instrument: .AUD, quantity: -42, type: .expense)
    ],
    transferSuggestion: nil)
  return Form {
    TransactionDetailTransferSuggestion(
      transaction: transaction,
      transactionStore: store,
      showDismissConfirmation: $showDismissConfirmation)
  }
  .formStyle(.grouped)
}
