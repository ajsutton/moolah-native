import SwiftUI

/// "Delete" section: a destructive button that requests deletion via the
/// parent-supplied `onRequestDelete` closure. The parent owns the
/// confirmation dialog so the destructive `onDelete` callback fires from
/// the same place as other parent-driven dismissal logic.
struct TransactionDetailDeleteSection: View {
  let onRequestDelete: () -> Void

  var body: some View {
    Section {
      Button(role: .destructive) {
        onRequestDelete()
      } label: {
        Text("Delete")
          .frame(maxWidth: .infinity)
      }
    }
  }
}
