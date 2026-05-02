import SwiftUI

// Sign-handling note:
// `TransactionDraft.displaysNegated(.trade) == false`, so the user enters
// signed quantities directly into Paid and Received and the storage matches
// 1:1. Trade reversals legitimately have unconventional signs, so the editor
// preserves whatever the user types — see CLAUDE.md "Monetary Sign
// Convention" and `feedback_no_abs_on_trade_legs.md` (no abs, no sign-by-
// position).
/// Trade-mode primary section. Mirrors the structure of
/// `TransactionDetailDetailsSection` + `TransactionDetailAccountSection` for
/// transfers, but with a single shared account picker and dual amount
/// rows. See design §3.2.
struct TransactionDetailTradeSection: View {
  @Binding var draft: TransactionDraft
  let accounts: Accounts
  @FocusState.Binding var focusedField: TransactionDetailFocus?

  var body: some View {
    Section("Trade") {
      accountPicker
      paidRow
      receivedRow
      if let rateText = derivedRateText {
        Text(rateText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .accessibilityLabel(rateText)
      }
    }
  }

  private var accountBinding: Binding<UUID?> {
    Binding(
      get: { draft.legDrafts.first?.accountId },
      set: { newId in
        for index in draft.legDrafts.indices {
          draft.legDrafts[index].accountId = newId
          if let id = newId, let account = accounts.by(id: id),
            draft.legDrafts[index].type == .expense
          {
            // Default new fee instruments to the account's currency.
            draft.legDrafts[index].instrument =
              draft.legDrafts[index].instrument ?? account.instrument
          }
        }
      }
    )
  }

  private var accountPicker: some View {
    Picker("Account", selection: accountBinding) {
      Text("None").tag(UUID?.none)
      AccountPickerOptions(
        accounts: accounts,
        exclude: nil,
        currentSelection: accountBinding.wrappedValue
      )
    }
    .accessibilityIdentifier(UITestIdentifiers.Detail.tradeAccount)
    #if os(macOS)
      .pickerStyle(.menu)
    #endif
  }

  private var paidRow: some View {
    legAmountRow(
      label: "Paid",
      indexAccessor: { draft.paidLegIndex },
      focus: .tradePaidAmount,
      identifier: UITestIdentifiers.Detail.tradePaidAmount,
      instrumentIdentifier: UITestIdentifiers.Detail.tradePaidInstrument
    )
  }

  private var receivedRow: some View {
    legAmountRow(
      label: "Received",
      indexAccessor: { draft.receivedLegIndex },
      focus: .tradeReceivedAmount,
      identifier: UITestIdentifiers.Detail.tradeReceivedAmount,
      instrumentIdentifier: UITestIdentifiers.Detail.tradeReceivedInstrument
    )
  }

  private func defaultInstrument(forLegAt idx: Int) -> Instrument {
    draft.legDrafts[idx].resolvedInstrument(accounts: accounts, earmarks: Earmarks(from: []))
  }

  @ViewBuilder
  private func legAmountRow(
    label: LocalizedStringKey,
    indexAccessor: () -> Int?,
    focus: TransactionDetailFocus,
    identifier: String,
    instrumentIdentifier: String
  ) -> some View {
    if let idx = indexAccessor() {
      let amountBinding = Binding(
        get: { draft.legDrafts[idx].amountText },
        set: { draft.legDrafts[idx].amountText = $0 })
      let instrumentBinding = Binding<Instrument>(
        get: { draft.legDrafts[idx].instrument ?? defaultInstrument(forLegAt: idx) },
        set: { draft.legDrafts[idx].instrument = $0 })

      LabeledContent {
        HStack(spacing: 8) {
          TextField(label, text: amountBinding)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            #if os(iOS)
              .keyboardType(.decimalPad)
            #endif
            .focused($focusedField, equals: focus)
            .accessibilityIdentifier(identifier)
          CompactInstrumentPickerButton(selection: instrumentBinding)
            .accessibilityIdentifier(instrumentIdentifier)
        }
      } label: {
        Text(label)
      }
    }
  }

  /// Derived rate caption: `≈ 1 {received} = X.XX {paid}`. Hidden when
  /// either side is unparseable or zero.
  private var derivedRateText: String? {
    guard let paidIdx = draft.paidLegIndex,
      let receivedIdx = draft.receivedLegIndex
    else { return nil }
    let paid = draft.legDrafts[paidIdx]
    let received = draft.legDrafts[receivedIdx]
    let paidInst = paid.instrument ?? defaultInstrument(forLegAt: paidIdx)
    let receivedInst = received.instrument ?? defaultInstrument(forLegAt: receivedIdx)
    guard
      let paidQty = InstrumentAmount.parseQuantity(
        from: paid.amountText, decimals: paidInst.decimals),
      let receivedQty = InstrumentAmount.parseQuantity(
        from: received.amountText, decimals: receivedInst.decimals),
      paidQty != 0, receivedQty != 0
    else { return nil }
    // `abs()` here applies to derived display ratios only; stored leg
    // quantities keep their signs untouched per the project sign convention.
    let rate = abs(paidQty / receivedQty)
    let rateFormatted = rate.formatted(
      .number.precision(.significantDigits(2...4)).grouping(.never))
    return "≈ 1 \(receivedInst.shortCode) = \(rateFormatted) \(paidInst.shortCode)"
  }
}
