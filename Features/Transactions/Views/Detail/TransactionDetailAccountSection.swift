import SwiftUI

/// Account picker for the relevant leg, plus — when the draft is a
/// transfer — the counterpart-account picker. When the resulting transfer
/// is cross-currency the section also embeds
/// `TransactionDetailCrossCurrencyRow` for the counterpart amount and the
/// derived exchange-rate caption.
struct TransactionDetailAccountSection: View {
  @Binding var draft: TransactionDraft
  let accounts: Accounts
  let relevantInstrument: Instrument?
  let counterpartInstrument: Instrument?
  let counterpartAmountBinding: Binding<String>
  let isCrossCurrency: Bool
  @FocusState.Binding var focusedField: TransactionDetailFocus?

  var body: some View {
    Section {
      Picker("Account", selection: $draft.legDrafts[draft.relevantLegIndex].accountId) {
        Text("None").tag(UUID?.none)
        AccountPickerOptions(
          accounts: accounts,
          exclude: nil,
          currentSelection: draft.legDrafts[draft.relevantLegIndex].accountId
        )
      }
      // Snap the relevant leg's instrument to the newly chosen account's
      // instrument so the inline picker on the Amount row tracks the
      // account. Mirrors the multi-leg row in `TransactionDetailLegRow`.
      .onChange(of: draft.legDrafts[draft.relevantLegIndex].accountId) { _, newAccountId in
        if let newAccountId, let account = accounts.by(id: newAccountId) {
          draft.legDrafts[draft.relevantLegIndex].instrument = account.instrument
        }
      }

      if draft.type == .transfer {
        transferRows
      }
    }
  }

  @ViewBuilder private var transferRows: some View {
    let counterpartIndex = draft.relevantLegIndex == 0 ? 1 : 0
    let toAccountLabel = draft.showFromAccount ? "From Account" : "To Account"
    let currentAccountId = draft.legDrafts[draft.relevantLegIndex].accountId
    let counterpartId = draft.legDrafts[counterpartIndex].accountId

    Picker(toAccountLabel, selection: $draft.legDrafts[counterpartIndex].accountId) {
      Text("Select...").tag(UUID?.none)
      AccountPickerOptions(
        accounts: accounts,
        exclude: currentAccountId,
        currentSelection: counterpartId
      )
    }
    .accessibilityIdentifier(UITestIdentifiers.Detail.toAccountPicker)
    .onChange(of: draft.legDrafts[counterpartIndex].accountId) { _, newAccountId in
      // Snap the counterpart leg's instrument to the new account before
      // mirroring amounts — the cross-currency picker reads the leg's
      // instrument first.
      if let newAccountId, let account = accounts.by(id: newAccountId) {
        draft.legDrafts[counterpartIndex].instrument = account.instrument
      }
      draft.snapToSameCurrencyIfNeeded(accounts: accounts)
    }

    if isCrossCurrency {
      TransactionDetailCrossCurrencyRow(
        draft: $draft,
        relevantInstrument: relevantInstrument,
        counterpartInstrument: counterpartInstrument,
        counterpartAmountBinding: counterpartAmountBinding,
        focusedField: $focusedField
      )
    }
  }
}
