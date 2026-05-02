import SwiftUI

// MARK: - Computed Helpers

extension TransactionDetailView {
  var isEditable: Bool { transaction.isSimple || transaction.isTrade || draft.isCustom }

  /// Whether the current draft is a simple earmark-only transaction.
  var isSimpleEarmarkOnly: Bool {
    !draft.isCustom && draft.relevantLeg.isEarmarkOnly
  }

  /// The instrument for the relevant leg's account (for displaying currency symbol).
  var relevantInstrument: Instrument? {
    draft.legDrafts[draft.relevantLegIndex].accountId
      .flatMap { accounts.by(id: $0) }?
      .instrument
  }

  /// Whether the current draft is a cross-currency simple transfer.
  var isCrossCurrency: Bool {
    !draft.isCustom && draft.type == .transfer && draft.isCrossCurrencyTransfer(accounts: accounts)
  }

  /// The instrument for the counterpart leg's account.
  var counterpartInstrument: Instrument? {
    draft.counterpartLeg?.accountId
      .flatMap { accounts.by(id: $0) }?
      .instrument
  }

  var counterpartAmountBinding: Binding<String> {
    Binding(
      get: { draft.counterpartLeg?.amountText ?? "" },
      set: { draft.setCounterpartAmount($0) }
    )
  }

  var amountBinding: Binding<String> {
    Binding(
      get: { draft.amountText },
      set: { draft.setAmount($0, accounts: accounts) }
    )
  }

  var isScheduled: Bool {
    showRecurrence && transaction.recurPeriod != nil
  }
}
