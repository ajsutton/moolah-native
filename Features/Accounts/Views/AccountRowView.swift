import SwiftUI

struct AccountRowView: View {
  let account: Account

  var body: some View {
    HStack {
      Image(systemName: iconName)
        .foregroundStyle(.secondary)
        .frame(width: UIConstants.IconSize.listIcon, height: UIConstants.IconSize.listIcon)
        .accessibilityLabel(account.type.rawValue)

      Text(account.name)

      Spacer()

      MonetaryAmountView(amount: account.displayBalance)
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
      balance: MonetaryAmount(cents: 123456, currency: Currency.AUD)
    )
  )
  .padding()
}
