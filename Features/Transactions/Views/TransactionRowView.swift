import SwiftUI

struct TransactionRowView: View {
  let transaction: Transaction
  let accounts: Accounts

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

      Text(Decimal(transaction.amount) / 100, format: .currency(code: Constants.defaultCurrency))
        .foregroundStyle(amountColor)
        .monospacedDigit()
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

  private var amountColor: Color {
    if transaction.amount > 0 { return .green }
    if transaction.amount < 0 { return .red }
    return .primary
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
    Account(id: savingsId, name: "Savings", type: .bank, balance: 500000)
  ])

  List {
    TransactionRowView(
      transaction: Transaction(
        type: .expense,
        date: Date(),
        accountId: UUID(),
        amount: -5023,
        payee: "Woolworths"
      ), accounts: accounts)
    TransactionRowView(
      transaction: Transaction(
        type: .income,
        date: Date(),
        accountId: UUID(),
        amount: 350000,
        payee: "Employer Pty Ltd"
      ), accounts: accounts)
    TransactionRowView(
      transaction: Transaction(
        type: .transfer,
        date: Date(),
        accountId: UUID(),
        toAccountId: savingsId,
        amount: -100000,
        payee: ""
      ), accounts: accounts)
    TransactionRowView(
      transaction: Transaction(
        type: .transfer,
        date: Date(),
        accountId: UUID(),
        toAccountId: savingsId,
        amount: -50000,
        payee: "Rent Split"
      ), accounts: accounts)
  }
}
