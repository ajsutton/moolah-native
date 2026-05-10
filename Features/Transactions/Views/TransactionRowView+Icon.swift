import SwiftUI

// MARK: - Leading-icon rendering

extension TransactionRowView {
  /// True when any leg's instrument is in the env-injected `spamInstruments`
  /// set. Drives the row-level grey-out and the leading-icon badge overlay.
  var rowIsSpam: Bool {
    transaction.legs.contains { spamInstruments.contains($0.instrument) }
  }

  /// The row's leading type-icon (income/expense/transfer/swap arrow) at
  /// its normal colour, dimmed to 50% when `rowIsSpam`, with a small yellow
  /// `exclamationmark.octagon.fill` badge overlaid on its bottom-trailing
  /// corner. The badge sits at full opacity so the spam signal stays vivid
  /// against the muted icon.
  var typeIconWithSpamBadge: some View {
    Image(systemName: iconName)
      .foregroundStyle(iconColor)
      .frame(width: UIConstants.IconSize.listIcon, height: UIConstants.IconSize.listIcon)
      .opacity(rowIsSpam ? 0.5 : 1.0)
      .overlay(alignment: .bottomTrailing) {
        if rowIsSpam {
          Image(systemName: "exclamationmark.octagon.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(.black, .yellow)
            .imageScale(.small)
            .accessibilityHidden(true)
        }
      }
      .accessibilityHidden(true)
  }

  var iconName: String {
    if transaction.isTrade { return "arrow.up.arrow.down" }
    guard transaction.isSimple, let type = transaction.legs.first?.type else {
      return "arrow.trianglehead.branch"
    }
    switch type {
    case .income: return "arrow.up"
    case .expense: return "arrow.down"
    case .transfer: return "arrow.left.arrow.right"
    case .openingBalance: return "flag.fill"
    case .trade: return "arrow.up.arrow.down"
    }
  }

  var iconColor: Color {
    if transaction.isTrade { return .indigo }
    guard transaction.isSimple, let type = transaction.legs.first?.type else {
      return .purple
    }
    switch type {
    case .income: return .green
    case .expense: return .red
    case .transfer: return .blue
    case .openingBalance: return .orange
    case .trade: return .indigo
    }
  }
}
