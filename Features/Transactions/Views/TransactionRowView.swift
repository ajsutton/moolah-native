import SwiftUI

struct TransactionRowView: View {
  let transaction: Transaction
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let balance: MonetaryAmount
  var hideEarmark: Bool = false

  var body: some View {
    HStack {
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
        MonetaryAmountView(amount: transaction.amount, font: .body)

        MonetaryAmountView(amount: balance, font: .caption)
      }
    }
    #if os(macOS)
      .padding(.vertical, 8)
    #else
      .padding(.vertical, 12)
    #endif
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityDescription)
  }

  private var accessibilityDescription: String {
    let dateStr = transaction.date.formatted(date: .abbreviated, time: .omitted)
    let amountStr = transaction.amount.decimalValue.formatted(
      .currency(code: transaction.amount.currency.code))
    let balanceStr = balance.decimalValue.formatted(.currency(code: balance.currency.code))
    return "\(displayPayee), \(amountStr), \(dateStr), balance \(balanceStr)"
  }

  private var iconName: String {
    switch transaction.type {
    case .income: return "arrow.up"
    case .expense: return "arrow.down"
    case .transfer: return "arrow.left.arrow.right"
    }
  }

  private var iconColor: Color {
    switch transaction.type {
    case .income: return .green
    case .expense: return .red
    case .transfer: return .blue
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
    guard let toAccountId = transaction.toAccountId else {
      return transaction.payee ?? ""
    }

    let toAccountName = accounts.by(id: toAccountId)?.name ?? "Unknown Account"
    let transferLabel = "Transfer to \(toAccountName)"

    if let payee = transaction.payee, !payee.isEmpty {
      return "\(payee) (\(transferLabel))"
    }
    return transferLabel
  }
}

#Preview {
  let savingsId = UUID()
  let groceriesId = UUID()
  let holidayFundId = UUID()
  let accounts = Accounts(from: [
    Account(
      id: savingsId, name: "Savings", type: .bank,
      balance: MonetaryAmount(cents: 500000, currency: Currency.defaultCurrency))
  ])
  let categories = Categories(from: [
    Category(id: groceriesId, name: "Groceries"),
    Category(name: "Transport"),
  ])
  let earmarks = Earmarks(from: [
    Earmark(
      id: holidayFundId,
      name: "Holiday Fund",
      balance: MonetaryAmount(cents: 50000, currency: Currency.defaultCurrency)
    )
  ])

  List {
    TransactionRowView(
      transaction: Transaction(
        type: .expense,
        date: Date(),
        accountId: UUID(),
        amount: MonetaryAmount(cents: -5023, currency: Currency.defaultCurrency),
        payee: "Woolworths",
        categoryId: groceriesId
      ), accounts: accounts, categories: categories, earmarks: earmarks,
      balance: MonetaryAmount(cents: 100000, currency: Currency.defaultCurrency))
    TransactionRowView(
      transaction: Transaction(
        type: .income,
        date: Date(),
        accountId: UUID(),
        amount: MonetaryAmount(cents: 350000, currency: Currency.defaultCurrency),
        payee: "Employer Pty Ltd",
        earmarkId: holidayFundId
      ), accounts: accounts, categories: categories, earmarks: earmarks,
      balance: MonetaryAmount(cents: 105023, currency: Currency.defaultCurrency))
    TransactionRowView(
      transaction: Transaction(
        type: .transfer,
        date: Date(),
        accountId: UUID(),
        toAccountId: savingsId,
        amount: MonetaryAmount(cents: -100000, currency: Currency.defaultCurrency),
        payee: ""
      ), accounts: accounts, categories: categories, earmarks: earmarks,
      balance: MonetaryAmount(cents: -244977, currency: Currency.defaultCurrency))
    TransactionRowView(
      transaction: Transaction(
        type: .transfer,
        date: Date(),
        accountId: UUID(),
        toAccountId: savingsId,
        amount: MonetaryAmount(cents: -50000, currency: Currency.defaultCurrency),
        payee: "Rent Split"
      ), accounts: accounts, categories: categories, earmarks: earmarks,
      balance: MonetaryAmount(cents: -144977, currency: Currency.defaultCurrency))
  }
}
