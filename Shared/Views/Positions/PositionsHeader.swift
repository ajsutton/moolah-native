import SwiftUI

/// Title + total + optional P&L pill. Visibility rules live in
/// `PositionsViewInput.showsPLPill` and `totalValue`.
struct PositionsHeader: View {
  let input: PositionsViewInput

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(input.title)
        .font(.headline)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer()
      if let total = input.totalValue {
        Text(total.formatted)
          .font(.headline)
          .monospacedDigit()
          .accessibilityLabel("Total \(total.formatted)")
      } else {
        Text("Unavailable")
          .font(.headline)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Total unavailable")
      }
      if input.showsPLPill, let gain = input.totalGainLoss, let total = input.totalValue {
        plPill(gain: gain, total: total)
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 12)
  }

  private func plPill(gain: InstrumentAmount, total: InstrumentAmount) -> some View {
    let cost = total - gain
    let percent: Double =
      cost.quantity == 0
      ? 0
      : Double(truncating: (gain.quantity / cost.quantity * 100) as NSDecimalNumber)
    let percentSign = percent > 0 ? "+" : ""
    let label = "\(gain.signedFormatted) (\(percentSign)\(String(format: "%.1f", abs(percent)))%)"
    return Text(label)
      .font(.caption.weight(.semibold))
      .monospacedDigit()
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        gainBackground(gain).opacity(0.15),
        in: Capsule()
      )
      .foregroundStyle(gainColor(gain))
      .accessibilityLabel(plPillAccessibilityLabel(gain: gain, percent: percent))
  }

  /// Foreground colour for gain / loss / zero — matches PositionRow + PositionsTable.
  private func gainColor(_ gain: InstrumentAmount) -> Color {
    if gain.isNegative { return .red }
    if gain.isZero { return .primary }
    return .green
  }

  /// Background tint for the pill capsule. Mirrors `gainColor` but always
  /// returns a non-`.primary` colour so the capsule has a visible fill.
  /// Zero-gain still uses `.green` for the capsule (with low opacity) so
  /// the pill doesn't disappear when displayed.
  private func gainBackground(_ gain: InstrumentAmount) -> Color {
    gain.isNegative ? .red : .green
  }

  private func plPillAccessibilityLabel(gain: InstrumentAmount, percent: Double) -> String {
    let pctFmt = String(format: "%.1f", abs(percent))
    if gain.isNegative {
      return "Down \((-gain).formatted), \(pctFmt) percent"
    }
    if gain.isZero {
      return "No change"
    }
    return "Up \(gain.formatted), \(pctFmt) percent"
  }
}

#Preview("Gain") {
  PositionsHeader(
    input: PositionsViewInput(
      title: "Brokerage",
      hostCurrency: .AUD,
      positions: [
        ValuedPosition(
          instrument: Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP"),
          quantity: 250,
          unitPrice: nil,
          costBasis: InstrumentAmount(quantity: 10_125, instrument: .AUD),
          value: InstrumentAmount(quantity: 11_325, instrument: .AUD)
        )
      ],
      historicalValue: nil
    )
  )
  .frame(width: 420)
}

#Preview("Loss") {
  PositionsHeader(
    input: PositionsViewInput(
      title: "Brokerage",
      hostCurrency: .AUD,
      positions: [
        ValuedPosition(
          instrument: Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP"),
          quantity: 250,
          unitPrice: nil,
          costBasis: InstrumentAmount(quantity: 11_325, instrument: .AUD),
          value: InstrumentAmount(quantity: 10_125, instrument: .AUD)
        )
      ],
      historicalValue: nil
    )
  )
  .frame(width: 420)
}

#Preview("Unavailable") {
  PositionsHeader(
    input: PositionsViewInput(
      title: "Brokerage",
      hostCurrency: .AUD,
      positions: [
        ValuedPosition(
          instrument: Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP"),
          quantity: 250,
          unitPrice: nil,
          costBasis: InstrumentAmount(quantity: 10_000, instrument: .AUD),
          value: nil
        )
      ],
      historicalValue: nil
    )
  )
  .frame(width: 420)
}
