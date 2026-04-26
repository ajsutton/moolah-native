import SwiftUI

/// Counterpart-amount input + derived-rate display shown for cross-currency
/// transfers. The label flips between "Sent" and "Received" so the field
/// always describes the *other* leg from the user's viewing perspective.
///
/// Stored amounts preserve their signs; only the display rate strips signs
/// so the printed ratio is always positive.
struct TransactionDetailCrossCurrencyRow: View {
  @Binding var draft: TransactionDraft
  let relevantInstrument: Instrument?
  let counterpartInstrument: Instrument?
  let counterpartAmountBinding: Binding<String>
  @FocusState.Binding var focusedField: TransactionDetailFocus?

  /// Display + accessibility text for the implied exchange rate. `nil`
  /// when either side is unparseable or zero.
  private var derivedRate: (displayText: String, accessibilityText: String)? {
    guard let relevantInst = relevantInstrument,
      let counterpartInst = counterpartInstrument,
      let primaryQty = InstrumentAmount.parseQuantity(
        from: draft.amountText, decimals: relevantInst.decimals),
      let counterQty = InstrumentAmount.parseQuantity(
        from: draft.counterpartLeg?.amountText ?? "", decimals: counterpartInst.decimals),
      primaryQty != .zero && counterQty != .zero
    else { return nil }
    // abs() used only for display rate computation — stored amounts preserve their signs
    let absPrimary = abs(primaryQty)
    let absCounter = abs(counterQty)
    let rate = absCounter / absPrimary
    let rateFormatted = rate.formatted(
      .number.precision(.significantDigits(2...4)).grouping(.never))
    return (
      displayText: "≈ 1 \(relevantInst.id) = \(rateFormatted) \(counterpartInst.id)",
      accessibilityText:
        "Approximate exchange rate: 1 \(relevantInst.id) equals \(rateFormatted) \(counterpartInst.id)"
    )
  }

  var body: some View {
    let fieldLabel = draft.showFromAccount ? "Sent" : "Received"
    HStack {
      Text(fieldLabel)
      Spacer()
      TextField(fieldLabel, text: counterpartAmountBinding)
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        .accessibilityLabel(draft.showFromAccount ? "Sent amount" : "Received amount")
        #if os(iOS)
          .keyboardType(.decimalPad)
        #endif
        .focused($focusedField, equals: .counterpartAmount)
        .onSubmit { focusedField = nil }
        .accessibilityIdentifier(UITestIdentifiers.Detail.counterpartAmount)
      Text(counterpartInstrument?.id ?? "")
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .accessibilityIdentifier(UITestIdentifiers.Detail.counterpartAmountInstrument)
    }

    if let rate = derivedRate {
      Text(rate.displayText)
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .accessibilityLabel(rate.accessibilityText)
    }
  }
}
