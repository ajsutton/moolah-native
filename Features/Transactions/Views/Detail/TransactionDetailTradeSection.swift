import SwiftUI

// Sign-handling note (Option C):
// `TransactionDraft.displaysNegated(.trade)` is `false`, so `amountText` stores
// the value exactly as the user types it — no negation at display or parse time.
// Design §3.2 envisions Paid as always-positive (mapping to a negative-quantity
// leg at serialise time), but implementing that mapping cleanly requires either a
// custom binding with abs/negate round-trip or changing the `displaysNegated` rule
// for only the Paid leg. For this iteration the editor accepts signed numbers
// literally: the user may type "300" (positive, maps to +300) or "-300" (negative,
// maps to -300). The label "Paid" still conveys intent; the forward mode-switch
// from Expense preserves the display text as-is (which is already positive for a
// normal expense). Fully positive-enforced fields are deferred to a follow-up.
/// Trade-mode primary section. Mirrors the structure of
/// `TransactionDetailDetailsSection` + `TransactionDetailAccountSection` for
/// transfers, but with a single shared account picker and dual amount
/// rows. See design §3.2.
struct TransactionDetailTradeSection: View {
  @Binding var draft: TransactionDraft
  let accounts: Accounts
  let sortedAccounts: [Account]
  let knownInstruments: [Instrument]
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
            draft.legDrafts[index].instrumentId =
              draft.legDrafts[index].instrumentId ?? account.instrument.id
          }
        }
      }
    )
  }

  private var accountPicker: some View {
    Picker("Account", selection: accountBinding) {
      Text("None").tag(UUID?.none)
      ForEach(sortedAccounts) { account in
        Text(account.name).tag(UUID?.some(account.id))
      }
    }
    .accessibilityIdentifier(UITestIdentifiers.Detail.tradeAccount)
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

  @ViewBuilder
  private func legAmountRow(
    label: String,
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
        get: {
          let id = draft.legDrafts[idx].instrumentId ?? Instrument.AUD.id
          return knownInstruments.first { $0.id == id } ?? Instrument.fiat(code: id)
        },
        set: { draft.legDrafts[idx].instrumentId = $0.id })

      HStack {
        Text(label)
        Spacer()
        TextField(label, text: amountBinding)
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          #if os(iOS)
            .keyboardType(.decimalPad)
          #endif
          .focused($focusedField, equals: focus)
          .accessibilityIdentifier(identifier)
        InstrumentPickerField(
          label: "",
          kinds: Set(Instrument.Kind.allCases),
          selection: instrumentBinding
        )
        .labelsHidden()
        .accessibilityIdentifier(instrumentIdentifier)
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
    let paidInst =
      paid.instrumentId.flatMap { id in
        knownInstruments.first { $0.id == id } ?? Instrument.fiat(code: id)
      } ?? Instrument.AUD
    let receivedInst =
      received.instrumentId.flatMap { id in
        knownInstruments.first { $0.id == id } ?? Instrument.fiat(code: id)
      } ?? Instrument.AUD
    guard
      let paidQty = InstrumentAmount.parseQuantity(
        from: paid.amountText, decimals: paidInst.decimals),
      let receivedQty = InstrumentAmount.parseQuantity(
        from: received.amountText, decimals: receivedInst.decimals),
      paidQty != 0, receivedQty != 0
    else { return nil }
    let rate = paidQty / receivedQty
    let rateFormatted = rate.formatted(
      .number.precision(.significantDigits(2...4)).grouping(.never))
    return "≈ 1 \(receivedInst.id) = \(rateFormatted) \(paidInst.id)"
  }
}
