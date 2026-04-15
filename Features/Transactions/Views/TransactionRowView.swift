import SwiftUI

struct TransactionRowView: View {
  let transaction: Transaction
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let displayAmount: InstrumentAmount
  let balance: InstrumentAmount
  var hideEarmark: Bool = false
  var viewingAccountId: UUID? = nil

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
        .accessibilityLabel(transaction.type.rawValue.capitalized)

      VStack(alignment: .leading, spacing: 2) {
        Text(displayPayee)
          .lineLimit(1)

        HStack(spacing: 4) {
          Text(transaction.date, format: .dateTime.day().month(.abbreviated).year())
            .monospacedDigit()

          if let categoryName {
            Text("·")
            Label(categoryName, systemImage: "tag")
              .labelStyle(.iconOnly)
              .imageScale(.small)
            Text(categoryName)
          }

          if !hideEarmark, let earmarkName {
            Text("·")
            Label(earmarkName, systemImage: "bookmark.fill")
              .labelStyle(.iconOnly)
              .imageScale(.small)
            Text(earmarkName)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 2) {
        InstrumentAmountView(amount: displayAmount, font: .body)

        InstrumentAmountView(amount: balance, font: .caption)
      }
    }
    .padding(.vertical, verticalPadding)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityDescription)
  }

  private var accessibilityDescription: String {
    let dateStr = transaction.date.formatted(date: .abbreviated, time: .omitted)
    let amountStr = displayAmount.formatted
    let balanceStr = balance.formatted
    return "\(displayPayee), \(amountStr), \(dateStr), balance \(balanceStr)"
  }

  private var iconName: String {
    switch transaction.type {
    case .income: return "arrow.up"
    case .expense: return "arrow.down"
    case .transfer: return "arrow.left.arrow.right"
    case .openingBalance: return "flag.fill"
    }
  }

  private var iconColor: Color {
    switch transaction.type {
    case .income: return .green
    case .expense: return .red
    case .transfer: return .blue
    case .openingBalance: return .orange
    }
  }

  private var categoryName: String? {
    guard let categoryId = transaction.categoryId else { return nil }
    return categories.by(id: categoryId)?.name
  }

  private var earmarkName: String? {
    guard let earmarkId = transaction.earmarkId else { return nil }
    return earmarks.by(id: earmarkId)?.name
  }

  private var displayPayee: String {
    if transaction.isSimple, transaction.isTransfer, let viewingAccountId,
      let otherLeg = transaction.legs.first(where: { $0.accountId != viewingAccountId })
    {
      let otherAccountName =
        accounts.by(id: otherLeg.accountId ?? UUID())?.name ?? "Unknown Account"
      let viewingLeg = transaction.legs.first(where: { $0.accountId == viewingAccountId })
      let isOutgoing = (viewingLeg?.quantity ?? 0) < 0
      let transferLabel =
        isOutgoing
        ? "Transfer to \(otherAccountName)"
        : "Transfer from \(otherAccountName)"

      if let payee = transaction.payee, !payee.isEmpty {
        return "\(payee) (\(transferLabel))"
      }
      return transferLabel
    }

    if !transaction.isSimple {
      if let payee = transaction.payee, !payee.isEmpty {
        return "\(payee) (\(transaction.legs.count) sub-transactions)"
      }
      return "\(transaction.legs.count) sub-transactions"
    }

    if let payee = transaction.payee, !payee.isEmpty {
      return payee
    }

    // Earmark transactions with no payee show a descriptive label
    if let earmarkId = transaction.earmarkId,
      let earmark = earmarks.by(id: earmarkId)
    {
      return "Earmark funds for \(earmark.name)"
    }

    return ""
  }
}

#Preview {
  let savingsId = UUID()
  let groceriesId = UUID()
  let holidayFundId = UUID()
  let sourceId = UUID()
  let accounts = Accounts(from: [
    Account(
      id: savingsId, name: "Savings", type: .bank,
      balance: InstrumentAmount(quantity: 5000, instrument: .AUD))
  ])
  let categories = Categories(from: [
    Category(id: groceriesId, name: "Groceries"),
    Category(name: "Transport"),
  ])
  let earmarks = Earmarks(from: [
    Earmark(
      id: holidayFundId,
      name: "Holiday Fund",
      balance: InstrumentAmount(quantity: 500, instrument: .AUD)
    )
  ])

  List {
    TransactionRowView(
      transaction: Transaction(
        date: Date(), payee: "Woolworths",
        legs: [
          TransactionLeg(
            accountId: sourceId, instrument: .AUD, quantity: -50.23, type: .expense,
            categoryId: groceriesId)
        ]
      ), accounts: accounts, categories: categories, earmarks: earmarks,
      displayAmount: InstrumentAmount(quantity: -50.23, instrument: .AUD),
      balance: InstrumentAmount(quantity: 1000, instrument: .AUD))
    TransactionRowView(
      transaction: Transaction(
        date: Date(), payee: "Employer Pty Ltd",
        legs: [
          TransactionLeg(
            accountId: sourceId, instrument: .AUD, quantity: 3500, type: .income,
            earmarkId: holidayFundId)
        ]
      ), accounts: accounts, categories: categories, earmarks: earmarks,
      displayAmount: InstrumentAmount(quantity: 3500, instrument: .AUD),
      balance: InstrumentAmount(quantity: 1050.23, instrument: .AUD))
    TransactionRowView(
      transaction: Transaction(
        date: Date(),
        legs: [
          TransactionLeg(accountId: sourceId, instrument: .AUD, quantity: -1000, type: .transfer),
          TransactionLeg(accountId: savingsId, instrument: .AUD, quantity: 1000, type: .transfer),
        ]
      ), accounts: accounts, categories: categories, earmarks: earmarks,
      displayAmount: InstrumentAmount(quantity: -1000, instrument: .AUD),
      balance: InstrumentAmount(quantity: -2449.77, instrument: .AUD),
      viewingAccountId: sourceId)
    TransactionRowView(
      transaction: Transaction(
        date: Date(), payee: "Rent Split",
        legs: [
          TransactionLeg(accountId: sourceId, instrument: .AUD, quantity: -500, type: .transfer),
          TransactionLeg(accountId: savingsId, instrument: .AUD, quantity: 500, type: .transfer),
        ]
      ), accounts: accounts, categories: categories, earmarks: earmarks,
      displayAmount: InstrumentAmount(quantity: -500, instrument: .AUD),
      balance: InstrumentAmount(quantity: -1449.77, instrument: .AUD),
      viewingAccountId: sourceId)
  }
}
