import SwiftUI

struct TransactionRowView: View {
    let transaction: Transaction

    var body: some View {
        HStack {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.payee ?? "No payee")
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
        case .income: return "arrow.down.circle"
        case .expense: return "arrow.up.circle"
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
}

#Preview {
    List {
        TransactionRowView(transaction: Transaction(
            type: .expense,
            date: Date(),
            accountId: UUID(),
            amount: -5023,
            payee: "Woolworths"
        ))
        TransactionRowView(transaction: Transaction(
            type: .income,
            date: Date(),
            accountId: UUID(),
            amount: 350000,
            payee: "Employer Pty Ltd"
        ))
        TransactionRowView(transaction: Transaction(
            type: .transfer,
            date: Date(),
            accountId: UUID(),
            toAccountId: UUID(),
            amount: -100000,
            payee: "To Savings"
        ))
    }
}
