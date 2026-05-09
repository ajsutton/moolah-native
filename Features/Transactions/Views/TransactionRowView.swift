import SwiftUI

struct TransactionRowView: View {
  let transaction: Transaction
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let displayAmounts: [InstrumentAmount]
  let balance: InstrumentAmount?
  let scopeReferenceInstrument: Instrument
  var hideEarmark: Bool = false
  var viewingAccountId: UUID?

  /// When true, the payee header shows a red `exclamationmark.triangle.fill`
  /// leading icon and the payee text renders in red. Used by the
  /// `.scheduledStatus` grouping for overdue rows.
  var isOverdue: Bool = false

  /// When true, the date in the meta row renders in orange and bold,
  /// indicating the scheduled transaction is due today. Used by the
  /// `.scheduledStatus` grouping.
  var isDueToday: Bool = false

  /// Optional inline Pay button. When non-nil, the row renders a trailing
  /// "Pay" button that invokes the closure. When nil (the default), no
  /// button is rendered. Used by the `.scheduledStatus` grouping.
  var onPay: (() -> Void)?

  /// When non-nil and equal to this row's transaction id, the inline Pay
  /// area is replaced by a small `ProgressView` with a payee-parameterised
  /// `.accessibilityLabel`, and the row is `.disabled(true)`. Used by the
  /// `.scheduledStatus` grouping for the in-progress pay flow.
  var pendingPayId: Transaction.ID?

  #if os(macOS)
    @ScaledMetric private var verticalPadding: CGFloat = 8
  #else
    @ScaledMetric private var verticalPadding: CGFloat = 12
  #endif

  // MARK: - Body & View Builders

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Image(systemName: iconName)
        .foregroundStyle(iconColor)
        .frame(width: UIConstants.IconSize.listIcon, height: UIConstants.IconSize.listIcon)
        .accessibilityHidden(true)
      infoColumn
      Spacer()
      amountColumn
      payAffordance
    }
    .padding(.vertical, verticalPadding)
    .disabled(isPaying)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityDescription)
  }

  private var infoColumn: some View {
    VStack(alignment: .leading, spacing: 2) {
      titleRow
      metadataRow
    }
  }

  private var titleRow: some View {
    HStack(spacing: 4) {
      if isOverdue {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .imageScale(.small)
          .accessibilityHidden(true)
      }
      Text(titleText)
        .lineLimit(1)
        .foregroundStyle(isOverdue ? Color.red : Color.primary)
    }
  }

  private var metadataRow: some View {
    HStack(spacing: 4) {
      Text(transaction.date, format: .dateTime.day().month(.abbreviated).year())
        .foregroundStyle(isDueToday ? Color.orange : Color.secondary)
        .fontWeight(isDueToday ? .semibold : .regular)
        .monospacedDigit()
      if let recurrence = recurrenceDescription {
        Text("·")
        Text(recurrence)
      }
      ForEach(categoryNames, id: \.self) { name in
        Text("·")
        Label(name, systemImage: "tag")
          .labelStyle(.iconOnly)
          .imageScale(.small)
        Text(name)
      }
      if !hideEarmark {
        ForEach(earmarkNames, id: \.self) { name in
          Text("·")
          Label(name, systemImage: "bookmark.fill")
            .labelStyle(.iconOnly)
            .imageScale(.small)
          Text(name)
        }
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  @ViewBuilder private var payAffordance: some View {
    if isPaying {
      ProgressView()
        .controlSize(.small)
        .accessibilityLabel("Paying \(displayPayee), please wait")
    } else if let onPay {
      Button("Pay") { onPay() }
        #if os(iOS)
          .buttonStyle(.borderedProminent)
          .controlSize(.regular)
        #else
          .buttonStyle(.bordered)
          .controlSize(.small)
        #endif
        .accessibilityLabel("Pay \(displayPayee)")
    }
  }

  // MARK: - Computed Display Properties

  private var isPaying: Bool {
    pendingPayId != nil && pendingPayId == transaction.id
  }

  private var recurrenceDescription: String? {
    guard let period = transaction.recurPeriod,
      let every = transaction.recurEvery,
      period != .once
    else {
      return nil
    }
    return period.recurrenceDescription(every: every)
  }

  private var amountColumn: some View {
    VStack(alignment: .trailing, spacing: 2) {
      if displayAmounts.isEmpty {
        Text("—")
          .font(.body)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      } else {
        TradeAmountFlow(amounts: displayAmounts)
      }
      if let balance {
        InstrumentAmountView(amount: balance, font: .caption)
      }
    }
  }

  private var accessibilityDescription: String {
    let dateStr = transaction.date.formatted(date: .abbreviated, time: .omitted)
    let amountStr =
      displayAmounts.isEmpty
      ? "amount unavailable"
      : displayAmounts.map(\.formatted).joined(separator: " and ")
    let typeStr: String
    if transaction.isTrade {
      typeStr = TransactionType.trade.displayName
    } else if transaction.isSimple, let type = transaction.legs.first?.type {
      typeStr = type.displayName
    } else {
      typeStr = "Custom transaction"
    }
    var parts: [String] = []
    if isOverdue {
      parts.append("Overdue")
    }
    parts.append(typeStr)
    parts.append(titleText)
    parts.append(amountStr)
    if isDueToday {
      parts.append("due today, \(dateStr)")
    } else {
      parts.append(dateStr)
    }
    if let balance {
      parts.append("balance \(balance.formatted)")
    }
    if let recurrence = recurrenceDescription {
      parts.append("repeats \(recurrence)")
    }
    return parts.joined(separator: ", ")
  }

  private var iconName: String {
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

  private var iconColor: Color {
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

  private var categoryNames: [String] {
    let applicable =
      viewingAccountId.map { id in
        transaction.legs.filter { $0.accountId == id }
      } ?? transaction.legs
    let uniqueIds = applicable.compactMap(\.categoryId).uniqued()
    return uniqueIds.compactMap { id in categories.by(id: id).map { categories.path(for: $0) } }
  }

  private var earmarkNames: [String] {
    let applicable =
      viewingAccountId.map { id in
        transaction.legs.filter { $0.accountId == id }
      } ?? transaction.legs
    let uniqueIds = applicable.compactMap(\.earmarkId).uniqued()
    return uniqueIds.compactMap { earmarks.by(id: $0)?.name }
  }

  private var displayPayee: String {
    transaction.displayPayee(
      viewingAccountId: viewingAccountId, accounts: accounts, earmarks: earmarks)
  }

  private var titleText: String {
    let payee = displayPayee
    if let sentence = transaction.tradeTitleSentence(scopeReference: scopeReferenceInstrument) {
      return payee.isEmpty ? sentence : "\(payee) (\(sentence))"
    }
    return payee
  }
}

// MARK: - Supporting Types

/// Inline-with-wrap layout for the row's per-instrument amount entries.
/// Lays out children horizontally with hairline spacing; wraps to a new
/// line when there isn't horizontal room. SwiftUI 6 / iOS 26 supports
/// `.layoutDirectionBehavior` and the `Layout` protocol — using a thin
/// custom `Layout` here keeps wrapping deterministic without nesting
/// `ViewThatFits`.
private struct TradeAmountFlow: View {
  let amounts: [InstrumentAmount]
  var body: some View {
    WrappedHStack(spacing: 6) {
      ForEach(amounts, id: \.self) { amount in
        InstrumentAmountView(amount: amount, font: .body)
      }
    }
    .multilineTextAlignment(.trailing)
  }
}

/// Minimal trailing-aligned wrap layout. Lays each subview out on the
/// current line if it fits within the proposed width; otherwise wraps.
private struct WrappedHStack: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    var lineWidth: CGFloat = 0
    var totalWidth: CGFloat = 0
    var totalHeight: CGFloat = 0
    var lineHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      let advance = (lineWidth == 0 ? 0 : spacing) + size.width
      if lineWidth + advance > maxWidth {
        totalWidth = max(totalWidth, lineWidth)
        totalHeight += lineHeight + spacing
        lineWidth = size.width
        lineHeight = size.height
      } else {
        lineWidth += advance
        lineHeight = max(lineHeight, size.height)
      }
    }
    totalWidth = max(totalWidth, lineWidth)
    totalHeight += lineHeight
    return CGSize(width: totalWidth, height: totalHeight)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    // Right-aligned wrap. Build line-by-line, then place trailing-justified.
    var lines: [[(index: Int, size: CGSize)]] = [[]]
    var lineWidth: CGFloat = 0
    let maxWidth = bounds.width
    for (index, subview) in subviews.enumerated() {
      let size = subview.sizeThatFits(.unspecified)
      let advance = (lineWidth == 0 ? 0 : spacing) + size.width
      if lineWidth + advance > maxWidth, !lines[lines.count - 1].isEmpty {
        lines.append([])
        lineWidth = 0
      }
      lines[lines.count - 1].append((index, size))
      lineWidth += (lineWidth == 0 ? size.width : advance)
    }
    var y = bounds.minY
    for line in lines {
      let lineHeight = line.map(\.size.height).max() ?? 0
      let totalLineWidth =
        line.reduce(0) { $0 + $1.size.width }
        + CGFloat(max(line.count - 1, 0)) * spacing
      var x = bounds.maxX - totalLineWidth
      for (index, size) in line {
        subviews[index].place(
          at: CGPoint(x: x, y: y),
          proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += lineHeight + spacing
    }
  }
}
