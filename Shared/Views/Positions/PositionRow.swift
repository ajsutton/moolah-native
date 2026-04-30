// swiftlint:disable multiline_arguments

import SwiftUI

/// Single-row presentation in `PositionsTable`. Used by both the wide
/// (`Table`) layout (where columns position the cells) and the narrow
/// (`List`) layout (where the row composes its own two-line layout).
///
/// Failed valuations render as `—` per `guides/UI_GUIDE.md`. Signs are
/// preserved across value, cost, and gain — the row never `abs()`s an amount.
struct PositionRow: View {
  let row: ValuedPosition

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      leadingColumn
      Spacer()
      trailingColumn
    }
    .padding(.vertical, 8)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
  }

  private var leadingColumn: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        KindBadge(kind: row.instrument.kind)
        Text(row.instrument.name)
          .font(.headline)
      }
      if let secondary = secondaryIdentifier {
        Text(secondary)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Text(row.quantityCaption)
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
  }

  private var trailingColumn: some View {
    VStack(alignment: .trailing, spacing: 2) {
      if let value = row.value {
        Text(value.formatted)
          .font(.body)
          .monospacedDigit()
      } else {
        Text("—")
          .foregroundStyle(.tertiary)
      }
      if let gain = row.gainLoss {
        Text(gainCaption(gain: gain, percent: row.gainLossPercent))
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(gainColor(gain))
      }
    }
  }

  private var secondaryIdentifier: String? {
    switch row.instrument.kind {
    case .stock: return row.instrument.exchange
    case .cryptoToken:
      if let chainId = row.instrument.chainId {
        return Instrument.chainName(for: chainId)
      }
      return nil
    case .fiatCurrency: return nil
    }
  }

  private func gainColor(_ gain: InstrumentAmount) -> Color {
    if gain.isNegative { return .red }
    if gain.isZero { return .primary }
    return .green
  }

  /// `"+$1,200  +12.3%"` / `"−$50  −5.0%"` / `"$0  0.0%"`. The two
  /// segments are double-spaced so the eye separates them at caption
  /// size. When `costBasis` is missing, the percent segment is
  /// omitted and only the dollar gain is shown.
  ///
  /// Negative values use a Unicode minus (U+2212) for typographic
  /// consistency, matching `PositionsTable.gainCell`.
  private func gainCaption(gain: InstrumentAmount, percent: Decimal?) -> String {
    guard let percent else { return gain.signedFormatted }
    let absDouble = abs(Double(truncating: percent as NSDecimalNumber))
    let body = String(format: "%.1f", absDouble)
    let pctText: String
    if percent > 0 {
      pctText = "+\(body)%"
    } else if percent < 0 {
      pctText = "−\(body)%"
    } else {
      pctText = "\(body)%"
    }
    return "\(gain.signedFormatted)  \(pctText)"
  }

  /// Constructs the ", up 12.3 percent" / ", down 5.0 percent" /
  /// ", 0.0 percent" suffix for the accessibility label, or an empty
  /// string when the percent is unavailable.
  private func pctSuffix(for percent: Decimal?) -> String {
    guard let percent else { return "" }
    let absValue = percent < 0 ? -percent : percent
    let formatted = String(format: "%.1f", Double(truncating: absValue as NSDecimalNumber))
    if percent == 0 { return ", 0.0 percent" }
    return percent < 0 ? ", down \(formatted) percent" : ", up \(formatted) percent"
  }

  private var accessibilityLabel: String {
    var parts: [String] = [row.instrument.name, row.quantityCaption]
    if let value = row.value {
      parts.append("valued at \(value.formatted)")
    } else {
      parts.append("value unavailable")
    }
    if let gain = row.gainLoss {
      let pctSuffix = pctSuffix(for: row.gainLossPercent)
      if gain.isNegative {
        parts.append("loss of \((-gain).formatted)\(pctSuffix)")
      } else if gain.isZero {
        parts.append(pctSuffix.isEmpty ? "no change" : "no change\(pctSuffix)")
      } else {
        parts.append("gain of \(gain.formatted)\(pctSuffix)")
      }
    }
    return parts.joined(separator: ", ")
  }
}

/// Coloured badge prefix for a row, distinguishing instrument kinds at a
/// glance. Colours are semantic (no hardcoded RGB).
struct KindBadge: View {
  let kind: Instrument.Kind

  var body: some View {
    let (label, tint): (String, Color) = {
      switch kind {
      case .stock: return ("S", .blue)
      case .cryptoToken: return ("C", .orange)
      case .fiatCurrency: return ("$", .indigo)
      }
    }()
    Text(label)
      .font(.caption2.weight(.bold))
      .foregroundStyle(.white)
      .frame(width: 18, height: 18)
      .background(tint, in: RoundedRectangle(cornerRadius: 4))
      .accessibilityHidden(true)
  }
}

private func previewRows() -> [ValuedPosition] {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  let aud = Instrument.AUD
  return [
    ValuedPosition(
      instrument: bhp, quantity: 250,
      unitPrice: InstrumentAmount(quantity: 45.30, instrument: aud),
      costBasis: InstrumentAmount(quantity: 10_125, instrument: aud),
      value: InstrumentAmount(quantity: 11_325, instrument: aud)),
    ValuedPosition(
      instrument: eth, quantity: 2.45,
      unitPrice: InstrumentAmount(quantity: 4_000, instrument: aud),
      costBasis: InstrumentAmount(quantity: 7_500, instrument: aud),
      value: InstrumentAmount(quantity: 9_800, instrument: aud)),
    ValuedPosition(
      instrument: aud, quantity: 1_520,
      unitPrice: nil, costBasis: nil,
      value: InstrumentAmount(quantity: 1_520, instrument: aud)),
    ValuedPosition(
      instrument: bhp, quantity: 100,
      unitPrice: nil, costBasis: nil, value: nil),
    ValuedPosition(
      instrument: bhp, quantity: 50,
      unitPrice: InstrumentAmount(quantity: 30, instrument: aud),
      costBasis: InstrumentAmount(quantity: 2_000, instrument: aud),
      value: InstrumentAmount(quantity: 1_500, instrument: aud)),
  ]
}

#Preview("rows") {
  List {
    ForEach(previewRows()) { row in
      PositionRow(row: row)
    }
  }
  .frame(width: 420)
}
