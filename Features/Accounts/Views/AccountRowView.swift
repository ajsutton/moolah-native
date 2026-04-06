import SwiftUI

struct AccountRowView: View {
  let account: Account

  var body: some View {
    HStack {
      Image(systemName: iconName)
        .foregroundStyle(.secondary)
        .frame(width: 24)

      Text(account.name)

      Spacer()

      Text(Decimal(account.balance) / 100, format: .currency(code: Constants.defaultCurrency))
        .foregroundStyle(account.balance < 0 ? .red : .primary)
        .monospacedDigit()
    }
  }

  private var iconName: String {
    switch account.type {
    case .bank: return "building.columns"
    case .asset: return "house.fill"
    case .creditCard: return "creditcard"
    case .investment: return "chart.line.uptrend.xyaxis"
    }
  }
}

#Preview {
  AccountRowView(
    account: Account(
      name: "Bank",
      type: .bank,
      balance: 123456
    )
  )
  .padding()
}
