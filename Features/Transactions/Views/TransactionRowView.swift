import SwiftUI

struct TransactionRowView: View {
  let transaction: Transaction
  let accounts: Accounts
  let balance: MonetaryAmount

  var body: some View {
    HStack {
      Image(systemName: iconName)
        .foregroundStyle(iconColor)
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 2) {
        Text(displayPayee)
          .lineLimit(1)

        Text(transaction.date, format: .dateTime.day().month(.abbreviated).year())
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 2) {
        MonetaryAmountView(amount: transaction.amount)

        MonetaryAmountView(amount: balance)
      }
    }
    .padding(.vertical, 2)
  }

  private var iconName: String {
    switch transaction.type {
    case .income: return "arrow.up.circle"
    case .expense: return "arrow.down.circle"
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
  let accounts = Accounts(from: [
    Account(
      id: savingsId, name: "Savings", type: .bank,
      balance: MonetaryAmount(cents: 500000, currency: Currency.defaultCurrency))
  ])

  List {
    TransactionRowView(
      transaction: Transaction(
        type: .expense,
        date: Date(),
        accountId: UUID(),
        amount: MonetaryAmount(cents: -5023, currency: Currency.defaultCurrency),
        payee: "Woolworths"
      ), accounts: accounts,
      balance: MonetaryAmount(cents: 100000, currency: Currency.defaultCurrency))
    TransactionRowView(
      transaction: Transaction(
        type: .income,
        date: Date(),
        accountId: UUID(),
        amount: MonetaryAmount(cents: 350000, currency: Currency.defaultCurrency),
        payee: "Employer Pty Ltd"
      ), accounts: accounts,
      balance: MonetaryAmount(cents: 105023, currency: Currency.defaultCurrency))
    TransactionRowView(
      transaction: Transaction(
        type: .transfer,
        date: Date(),
        accountId: UUID(),
        toAccountId: savingsId,
        amount: MonetaryAmount(cents: -100000, currency: Currency.defaultCurrency),
        payee: ""
      ), accounts: accounts,
      balance: MonetaryAmount(cents: -244977, currency: Currency.defaultCurrency))
    TransactionRowView(
      transaction: Transaction(
        type: .transfer,
        date: Date(),
        accountId: UUID(),
        toAccountId: savingsId,
        amount: MonetaryAmount(cents: -50000, currency: Currency.defaultCurrency),
        payee: "Rent Split"
      ), accounts: accounts,
      balance: MonetaryAmount(cents: -144977, currency: Currency.defaultCurrency))
  }
}
