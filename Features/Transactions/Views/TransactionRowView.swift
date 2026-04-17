import SwiftUI

struct TransactionRowView: View {
  let transaction: Transaction
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let displayAmount: InstrumentAmount?
  let balance: InstrumentAmount?
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
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(displayPayee)
          .lineLimit(1)

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

      Spacer()

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
    .padding(.vertical, verticalPadding)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityDescription)
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
    return uniqueIds.compactMap { categories.by(id: $0)?.name }
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

#Preview {
  let savingsId = UUID()
  let groceriesId = UUID()
  let holidayFundId = UUID()
  let sourceId = UUID()
  let accounts = Accounts(from: [
    Account(
      id: savingsId, name: "Savings", type: .bank, instrument: .AUD,
      positions: [Position(instrument: .AUD, quantity: 5000)])
  ])
  let categories = Categories(from: [
    Category(id: groceriesId, name: "Groceries"),
    Category(name: "Transport"),
  ])
  let earmarks = Earmarks(from: [
    Earmark(
      id: holidayFundId,
      name: "Holiday Fund",
      instrument: .AUD
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
    TransactionRowView(
      transaction: Transaction(
        date: Date(), payee: "Stock Trade",
        legs: [
          TransactionLeg(
            accountId: sourceId, instrument: .AUD, quantity: -1000, type: .transfer),
          TransactionLeg(
            accountId: savingsId, instrument: .AUD, quantity: 950, type: .transfer),
          TransactionLeg(accountId: sourceId, instrument: .AUD, quantity: -50, type: .expense),
        ]
      ), accounts: accounts, categories: categories, earmarks: earmarks,
      displayAmount: InstrumentAmount(quantity: -1050, instrument: .AUD),
      balance: InstrumentAmount(quantity: -2499.77, instrument: .AUD),
      viewingAccountId: sourceId)
  }
}
