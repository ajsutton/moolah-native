import SwiftUI

struct EarmarkRowView: View {
  let earmark: Earmark

  var body: some View {
    SidebarRowView(
      icon: "bookmark.fill",
      name: earmark.name,
      amount: earmark.balance
    )
  }
}

#Preview {
  List {
    EarmarkRowView(
      earmark: Earmark(
        name: "Holiday Fund",
        balance: MonetaryAmount(cents: 150000, currency: Currency.AUD),
        savingsGoal: MonetaryAmount(cents: 500000, currency: Currency.AUD)
      ))
    EarmarkRowView(
      earmark: Earmark(
        name: "Emergency Fund",
        balance: MonetaryAmount(cents: 300000, currency: Currency.AUD)
      ))
  }
}
