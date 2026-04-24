// swiftlint:disable multiline_arguments

import SwiftUI

struct TransactionRowView: View {
  let transaction: Transaction
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let displayAmount: InstrumentAmount?
  let balance: InstrumentAmount?
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
      Text(displayPayee).lineLimit(1)
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
      if let displayAmount {
        InstrumentAmountView(amount: displayAmount, font: .body)
      } else {
        Text("—")
          .font(.body)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      if let balance {
        InstrumentAmountView(amount: balance, font: .caption)
      }
    }
  }

  private var accessibilityDescription: String {
    let dateStr = transaction.date.formatted(date: .abbreviated, time: .omitted)
    let amountStr = displayAmount?.formatted ?? "amount unavailable"
    let typeStr: String
    if transaction.isSimple, let type = transaction.legs.first?.type {
      typeStr = type.displayName
    } else {
      typeStr = "Custom transaction"
    }
    if let balance {
      return
        "\(typeStr), \(displayPayee), \(amountStr), \(dateStr), balance \(balance.formatted)"
    } else {
      return "\(typeStr), \(displayPayee), \(amountStr), \(dateStr)"
    }
  }

  private var iconName: String {
    guard transaction.isSimple, let type = transaction.legs.first?.type else {
      return "arrow.trianglehead.branch"
    }
    switch type {
    case .income: return "arrow.up"
    case .expense: return "arrow.down"
    case .transfer: return "arrow.left.arrow.right"
    case .openingBalance: return "flag.fill"
    }
  }

  private var iconColor: Color {
    guard transaction.isSimple, let type = transaction.legs.first?.type else {
      return .purple
    }
    switch type {
    case .income: return .green
    case .expense: return .red
    case .transfer: return .blue
    case .openingBalance: return .orange
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
  display: Decimal,
  balance: Decimal,
  viewingAccountId: UUID? = nil
) -> TransactionRowView {
  TransactionRowView(
    transaction: Transaction(date: Date(), payee: payee ?? "", legs: legs),
    accounts: data.accounts, categories: data.categories, earmarks: data.earmarks,
    displayAmount: InstrumentAmount(quantity: display, instrument: .AUD),
    balance: InstrumentAmount(quantity: balance, instrument: .AUD),
    viewingAccountId: viewingAccountId)
}

private struct PreviewRowSpec {
  let payee: String?
  let legs: [TransactionLeg]
  let display: Decimal
  let balance: Decimal
  var viewingAccountId: UUID?
}

private func previewRowSpecs(data: TransactionRowPreviewData) -> [PreviewRowSpec] {
  [
    PreviewRowSpec(
      payee: "Woolworths",
      legs: [
        TransactionLeg(
          accountId: data.sourceId, instrument: .AUD, quantity: -50.23, type: .expense,
          categoryId: data.groceriesId)
      ],
      display: -50.23, balance: 1000),
    PreviewRowSpec(
      payee: "Employer Pty Ltd",
      legs: [
        TransactionLeg(
          accountId: data.sourceId, instrument: .AUD, quantity: 3500, type: .income,
          earmarkId: data.holidayFundId)
      ],
      display: 3500, balance: 1050.23),
    PreviewRowSpec(
      payee: nil,
      legs: [
        TransactionLeg(
          accountId: data.sourceId, instrument: .AUD, quantity: -1000, type: .transfer),
        TransactionLeg(
          accountId: data.savingsId, instrument: .AUD, quantity: 1000, type: .transfer),
      ],
      display: -1000, balance: -2449.77, viewingAccountId: data.sourceId),
    PreviewRowSpec(
      payee: "Rent Split",
      legs: [
        TransactionLeg(
          accountId: data.sourceId, instrument: .AUD, quantity: -500, type: .transfer),
        TransactionLeg(
          accountId: data.savingsId, instrument: .AUD, quantity: 500, type: .transfer),
      ],
      display: -500, balance: -1449.77, viewingAccountId: data.sourceId),
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
      display: -1050, balance: -2499.77, viewingAccountId: data.sourceId),
  ]
}

#Preview {
  let data = TransactionRowPreviewData()
  return List {
    ForEach(Array(previewRowSpecs(data: data).enumerated()), id: \.offset) { _, spec in
      previewRow(
        data: data, payee: spec.payee, legs: spec.legs,
        display: spec.display, balance: spec.balance,
        viewingAccountId: spec.viewingAccountId)
    }
  }
}
