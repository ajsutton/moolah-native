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
        case .checking: return "building.columns"
        case .savings: return "leaf"
        case .creditCard: return "creditcard"
        case .investment: return "chart.line.uptrend.xyaxis"
        case .earmark: return "tag"
        }
    }
}

#Preview {
    AccountRowView(account: Account(
        name: "Checking",
        type: .checking,
        balance: 123456
    ))
    .padding()
}
