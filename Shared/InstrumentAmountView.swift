import SwiftUI

/// Displays an InstrumentAmount with color coding:
/// green when positive, red when negative, primary when zero.
/// Use `colorOverride` to force a specific color (e.g. `.secondary` for running balances).
struct InstrumentAmountView: View {
  let amount: InstrumentAmount
  var font: Font?
  var colorOverride: Color?

  var body: some View {
    text
      .foregroundStyle(effectiveColor)
      .monospacedDigit()
      .font(font)
      .accessibilityLabel(Text("Amount"))
      .accessibilityValue(amount.formatted)
  }

  private var text: Text {
    switch amount.instrument.kind {
    case .fiatCurrency:
      Text(amount.quantity, format: .currency(code: amount.instrument.id))
    case .stock, .cryptoToken:
      Text(amount.formatted)
    }
  }

  private var effectiveColor: Color {
    if let colorOverride { return colorOverride }
    if amount.isPositive { return .green }
    if amount.isNegative { return .red }
    return .primary
  }
}
