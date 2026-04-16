import SwiftUI

/// Three-panel summary showing Current Value, Invested Amount, and ROI.
struct InvestmentSummaryView: View {
  let investedAmount: InstrumentAmount
  let currentValue: InstrumentAmount?
  let store: InvestmentStore

  var body: some View {
    HStack(spacing: 16) {
      SummaryPanel(
        label: "Current Value",
        amount: currentValue ?? investedAmount,
        subtitle: profitLossPercentText,
        subtitleColor: profitLossColor
      )

      Divider()
        .frame(height: 50)

      SummaryPanel(
        label: "Invested Amount",
        amount: investedAmount,
        subtitle: nil,
        subtitleColor: nil
      )

      Divider()
        .frame(height: 50)

      SummaryPanel(
        label: "ROI",
        amount: profitLoss,
        subtitle: annualizedReturnText,
        subtitleColor: profitLossColor
      )
    }
    .padding()
    .background(.background)
    .cornerRadius(12)
  }

  // MARK: - Computed

  private var effectiveCurrentValue: InstrumentAmount {
    currentValue ?? investedAmount
  }

  private var profitLoss: InstrumentAmount {
    effectiveCurrentValue - investedAmount
  }

  private var profitLossPercent: Double {
    guard !investedAmount.isZero else { return 0 }
    let balanceValue = Double(truncating: investedAmount.quantity as NSDecimalNumber)
    guard balanceValue != 0 else { return 0 }
    return Double(truncating: profitLoss.quantity as NSDecimalNumber) / balanceValue * 100
  }

  private var profitLossPercentText: String? {
    guard currentValue != nil else { return nil }
    let sign = profitLossPercent >= 0 ? "+" : ""
    return "\(sign)\(String(format: "%.1f", profitLossPercent))%"
  }

  private var profitLossColor: Color? {
    if profitLoss.isPositive { return .green }
    if profitLoss.isNegative { return .red }
    return .secondary
  }

  private var annualizedReturnText: String? {
    guard currentValue != nil else { return nil }
    let rate = store.annualizedReturnRate(currentValue: effectiveCurrentValue)
    guard rate.isFinite else { return nil }
    let sign = rate >= 0 ? "+" : ""
    return "\(sign)\(String(format: "%.1f", rate))% p.a."
  }
}

private struct SummaryPanel: View {
  let label: String
  let amount: InstrumentAmount
  let subtitle: String?
  let subtitleColor: Color?

  var body: some View {
    VStack(spacing: 4) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)

      InstrumentAmountView(amount: amount)
        .font(.headline)

      if let subtitle {
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(subtitleColor ?? .secondary)
          .monospacedDigit()
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }
}
