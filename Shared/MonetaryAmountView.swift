import SwiftUI

/// Displays a MonetaryAmount with color coding:
/// green when positive, red when negative, primary when zero.
/// Use `colorOverride` to force a specific color (e.g. `.secondary` for running balances).
struct MonetaryAmountView: View {
  let amount: MonetaryAmount
  var font: Font? = nil
  var colorOverride: Color? = nil

  var body: some View {
    Text(amount.decimalValue, format: .currency(code: amount.currency.code))
      .foregroundStyle(effectiveColor)
      .monospacedDigit()
      .font(font)
  }

  private var effectiveColor: Color {
    if let colorOverride { return colorOverride }
    if amount.isPositive { return .green }
    if amount.isNegative { return .red }
    return .primary
  }
}
