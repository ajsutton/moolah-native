import SwiftUI

/// "Add Sub-transaction" section in custom-mode editing. The new leg
/// inherits its default account and instrument from the first ordered
/// account so the user has a sensible starting point to edit from.
struct TransactionDetailAddLegSection: View {
  @Binding var draft: TransactionDraft
  let sortedAccounts: [Account]

  var body: some View {
    Section {
      Button("Add Sub-transaction") {
        let defaultAccount = sortedAccounts.first
        draft.addLeg(
          defaultAccountId: defaultAccount?.id,
          instrument: defaultAccount?.instrument
        )
      }
      .accessibilityLabel("Add Sub-transaction")
    }
  }
}
