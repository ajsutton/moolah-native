import SwiftUI

/// Displays an InstrumentAmount with color coding:
/// green when positive, red when negative, primary when zero.
/// Use `colorOverride` to force a specific color (e.g. `.secondary` for running balances).
struct MonetaryAmountView: View {
  let amount: InstrumentAmount
  var font: Font? = nil
  var colorOverride: Color? = nil

  var body: some View {
    Text(amount.quantity, format: .currency(code: amount.instrument.id))
      .foregroundStyle(effectiveColor)
      .monospacedDigit()
      .font(font)
      .accessibilityValue(amount.quantity.formatted(.currency(code: amount.instrument.id)))
  }

  private var effectiveColor: Color {
    if let colorOverride { return colorOverride }
    if amount.isPositive { return .green }
    if amount.isNegative { return .red }
    return .primary
  }
}
