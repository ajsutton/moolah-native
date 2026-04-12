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
        balance: InstrumentAmount(quantity: 1500, instrument: .AUD),
        savingsGoal: InstrumentAmount(quantity: 5000, instrument: .AUD)
      ))
    EarmarkRowView(
      earmark: Earmark(
        name: "Emergency Fund",
        balance: InstrumentAmount(quantity: 3000, instrument: .AUD)
      ))
  }
}
