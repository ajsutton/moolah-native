import SwiftUI

/// "Pay Now" section for scheduled transactions. Routes the result of
/// `TransactionStore.payScheduledTransaction(_:)` into the parent's
/// `onUpdate` (paid + new transaction returned) or `onDelete` callbacks
/// (paid with no future occurrence, or deleted).
struct TransactionDetailPaySection: View {
  let transaction: Transaction
  let transactionStore: TransactionStore
  let onUpdate: (Transaction) -> Void
  let onDelete: (UUID) -> Void

  var body: some View {
    Section {
      Button {
        Task {
          switch await transactionStore.payScheduledTransaction(transaction) {
          case .paid(let updated?): onUpdate(updated)
          case .paid(.none), .deleted: onDelete(transaction.id)
          case .failed: break
          }
        }
      } label: {
        HStack {
          Spacer()
          if transactionStore.isPayingScheduled {
            ProgressView()
              .controlSize(.small)
          } else {
            Text("Pay Now")
          }
          Spacer()
        }
      }
      .disabled(transactionStore.isPayingScheduled)
      .accessibilityLabel("Pay \(transaction.payee ?? "transaction") now")
    }
  }
}
