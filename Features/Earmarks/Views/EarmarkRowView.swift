import SwiftUI

struct EarmarkRowView: View {
  let earmark: Earmark

  var body: some View {
    HStack {
      Image(systemName: "bookmark.fill")
        .foregroundStyle(.secondary)
        .frame(width: 24)
        .accessibilityLabel("Earmark")

      Text(earmark.name)

      Spacer()

      MonetaryAmountView(amount: earmark.balance)
    }
  }
}

#Preview {
  List {
    EarmarkRowView(
      earmark: Earmark(
        name: "Holiday Fund",
        balance: MonetaryAmount(cents: 150000, currency: Currency.defaultCurrency),
        savingsGoal: MonetaryAmount(cents: 500000, currency: Currency.defaultCurrency)
      ))
    EarmarkRowView(
      earmark: Earmark(
        name: "Emergency Fund",
        balance: MonetaryAmount(cents: 300000, currency: Currency.defaultCurrency)
      ))
  }
}
