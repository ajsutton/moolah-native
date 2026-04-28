// swiftlint:disable multiline_arguments

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

  #if os(macOS)
    @ScaledMetric private var verticalPadding: CGFloat = 8
  #else
    @ScaledMetric private var verticalPadding: CGFloat = 12
  #endif

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Image(systemName: iconName)
        .foregroundStyle(iconColor)
        .frame(width: UIConstants.IconSize.listIcon, height: UIConstants.IconSize.listIcon)
        .accessibilityHidden(true)
      infoColumn
      Spacer()
      amountColumn
    }
    .padding(.vertical, verticalPadding)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityDescription)
  }

  private var infoColumn: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(titleText).lineLimit(1)
      metadataRow
    }
  }

  private var metadataRow: some View {
    HStack(spacing: 4) {
      Text(transaction.date, format: .dateTime.day().month(.abbreviated).year())
        .monospacedDigit()
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
    if let balance {
      return
        "\(typeStr), \(titleText), \(amountStr), \(dateStr), balance \(balance.formatted)"
    } else {
      return "\(typeStr), \(titleText), \(amountStr), \(dateStr)"
    }
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

private struct TransactionRowPreviewData {
  let sourceId = UUID()
  let savingsId = UUID()
  let groceriesId = UUID()
  let holidayFundId = UUID()

  var accounts: Accounts {
    Accounts(from: [
      Account(
        id: savingsId, name: "Savings", type: .bank, instrument: .AUD,
        positions: [Position(instrument: .AUD, quantity: 5000)])
    ])
  }
  var categories: Categories {
    Categories(from: [
      Category(id: groceriesId, name: "Groceries"),
      Category(name: "Transport"),
    ])
  }
  var earmarks: Earmarks {
    Earmarks(from: [
      Earmark(id: holidayFundId, name: "Holiday Fund", instrument: .AUD)
    ])
  }
}

private func previewRow(
  data: TransactionRowPreviewData,
  payee: String? = nil,
  legs: [TransactionLeg],
  displayAmounts: [InstrumentAmount],
  balance: Decimal,
  scopeReferenceInstrument: Instrument = .AUD,
  viewingAccountId: UUID? = nil
) -> TransactionRowView {
  TransactionRowView(
    transaction: Transaction(date: Date(), payee: payee ?? "", legs: legs),
    accounts: data.accounts, categories: data.categories, earmarks: data.earmarks,
    displayAmounts: displayAmounts,
    balance: InstrumentAmount(quantity: balance, instrument: .AUD),
    scopeReferenceInstrument: scopeReferenceInstrument,
    viewingAccountId: viewingAccountId)
}

private struct PreviewRowSpec {
  let payee: String?
  let legs: [TransactionLeg]
  let displayAmounts: [InstrumentAmount]
  let balance: Decimal
  var viewingAccountId: UUID?
}

private func previewRowSpecs(data: TransactionRowPreviewData) -> [PreviewRowSpec] {
  simplePreviewSpecs(data: data) + tradePreviewSpecs(data: data)
}

private func simplePreviewSpecs(data: TransactionRowPreviewData) -> [PreviewRowSpec] {
  [
    PreviewRowSpec(
      payee: "Woolworths",
      legs: [
        TransactionLeg(
          accountId: data.sourceId, instrument: .AUD, quantity: -50.23, type: .expense,
          categoryId: data.groceriesId)
      ],
      displayAmounts: [InstrumentAmount(quantity: -50.23, instrument: .AUD)],
      balance: 1000),
    PreviewRowSpec(
      payee: "Employer Pty Ltd",
      legs: [
        TransactionLeg(
          accountId: data.sourceId, instrument: .AUD, quantity: 3500, type: .income,
          earmarkId: data.holidayFundId)
      ],
      displayAmounts: [InstrumentAmount(quantity: 3500, instrument: .AUD)],
      balance: 1050.23),
    PreviewRowSpec(
      payee: nil,
      legs: [
        TransactionLeg(
          accountId: data.sourceId, instrument: .AUD, quantity: -1000, type: .transfer),
        TransactionLeg(
          accountId: data.savingsId, instrument: .AUD, quantity: 1000, type: .transfer),
      ],
      displayAmounts: [InstrumentAmount(quantity: -1000, instrument: .AUD)],
      balance: -2449.77, viewingAccountId: data.sourceId),
    PreviewRowSpec(
      payee: "Rent Split",
      legs: [
        TransactionLeg(
          accountId: data.sourceId, instrument: .AUD, quantity: -500, type: .transfer),
        TransactionLeg(
          accountId: data.savingsId, instrument: .AUD, quantity: 500, type: .transfer),
      ],
      displayAmounts: [InstrumentAmount(quantity: -500, instrument: .AUD)],
      balance: -1449.77, viewingAccountId: data.sourceId),
  ]
}

private func tradePreviewSpecs(data: TransactionRowPreviewData) -> [PreviewRowSpec] {
  [
    PreviewRowSpec(
      payee: "Stock Trade",
      legs: [
        TransactionLeg(
          accountId: data.sourceId, instrument: .AUD, quantity: -1000, type: .transfer),
        TransactionLeg(
          accountId: data.savingsId, instrument: .AUD, quantity: 950, type: .transfer),
        TransactionLeg(
          accountId: data.sourceId, instrument: .AUD, quantity: -50, type: .expense),
      ],
      displayAmounts: [
        InstrumentAmount(quantity: -1000, instrument: .AUD),
        InstrumentAmount(quantity: 950, instrument: .AUD),
        InstrumentAmount(quantity: -50, instrument: .AUD),
      ],
      balance: -2499.77, viewingAccountId: data.sourceId)
  ]
}

#Preview {
  let data = TransactionRowPreviewData()
  return List {
    ForEach(Array(previewRowSpecs(data: data).enumerated()), id: \.offset) { _, spec in
      previewRow(
        data: data, payee: spec.payee, legs: spec.legs,
        displayAmounts: spec.displayAmounts, balance: spec.balance,
        viewingAccountId: spec.viewingAccountId)
    }
  }
}
