import SwiftUI

/// Three-panel summary showing Current Value, Invested Amount, and ROI.
struct InvestmentSummaryView: View {
  let account: Account
  let store: InvestmentStore

  var body: some View {
    HStack(spacing: 16) {
      SummaryPanel(
        label: "Current Value",
        amount: account.investmentValue ?? account.balance,
        subtitle: profitLossPercentText,
        subtitleColor: profitLossColor
      )

      Divider()
        .frame(height: 50)

      SummaryPanel(
        label: "Invested Amount",
        amount: account.balance,
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
    #if os(macOS)
      .background(Color(nsColor: .controlBackgroundColor))
    #else
      .background(Color(uiColor: .systemBackground))
    #endif
    .cornerRadius(12)
  }

  // MARK: - Computed

  private var currentValue: MonetaryAmount {
    account.investmentValue ?? account.balance
  }

  private var profitLoss: MonetaryAmount {
    currentValue - account.balance
  }

  private var profitLossPercent: Double {
    guard account.balance.cents != 0 else { return 0 }
    return Double(profitLoss.cents) / Double(account.balance.cents) * 100
  }

  private var profitLossPercentText: String? {
    guard account.investmentValue != nil else { return nil }
    let sign = profitLossPercent >= 0 ? "+" : ""
    return "\(sign)\(String(format: "%.1f", profitLossPercent))%"
  }

  private var profitLossColor: Color? {
    if profitLoss.isPositive { return .green }
    if profitLoss.isNegative { return .red }
    return .secondary
  }

  private var annualizedReturnText: String? {
    guard account.investmentValue != nil else { return nil }
    let rate = store.annualizedReturnRate(currentValue: currentValue)
    guard rate.isFinite else { return nil }
    let sign = rate >= 0 ? "+" : ""
    return "\(sign)\(String(format: "%.1f", rate))% p.a."
  }
}

private struct SummaryPanel: View {
  let label: String
  let amount: MonetaryAmount
  let subtitle: String?
  let subtitleColor: Color?

  var body: some View {
    VStack(spacing: 4) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)

      MonetaryAmountView(amount: amount)
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
