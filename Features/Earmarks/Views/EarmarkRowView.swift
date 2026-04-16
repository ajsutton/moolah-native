import SwiftUI

struct EarmarkRowView: View {
  let earmark: Earmark
  @Environment(EarmarkStore.self) private var earmarkStore

  var body: some View {
    SidebarRowView(
      icon: "bookmark.fill",
      name: earmark.name,
      amount: earmarkStore.convertedBalance(for: earmark.id)
        ?? .zero(instrument: earmark.instrument)
    )
  }
}

#Preview {
  let (backend, _) = PreviewBackend.create()
  let earmarkStore = EarmarkStore(repository: backend.earmarks)

  List {
    EarmarkRowView(
      earmark: Earmark(
        name: "Holiday Fund",
        savingsGoal: InstrumentAmount(quantity: 5000, instrument: .AUD)
      ))
    EarmarkRowView(
      earmark: Earmark(
        name: "Emergency Fund"
      ))
  }
  .environment(earmarkStore)
}
