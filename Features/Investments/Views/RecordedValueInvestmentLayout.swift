import SwiftUI

/// Composition shell for the recorded-value (legacy) investment layout.
///
/// Used by `InvestmentAccountView` when `account.valuationMode ==
/// .recordedValue`. Renders the standard recorded-value layout:
/// performance summary above a chart/valuations panel, divider, then
/// the transactions list.
///
/// Named after the structural role (the layout used for
/// `valuationMode == .recordedValue`) rather than the temporal label
/// "legacy"; the source body in the leaf is `legacyValuationsLayout`
/// for historical reasons but the shell takes the structural name.
///
/// **Content-only.** Per `guides/UI_GUIDE.md` §3, composition shells
/// must not register `.toolbar` or `.searchable` themselves —
/// `TransactionListView` (passed in via the `transactions` slot)
/// owns the searchable, and `InvestmentAccountView` (the leaf caller)
/// owns its own `.transactionInspector`, `.profileNavigationTitle`,
/// `.sheet` modifiers at the leaf body level.
///
/// Outer `VStack(spacing: 0)`: per `guides/UI_GUIDE.md` §3.2 each slot
/// is responsible for its own internal padding (the chart panel pads
/// itself, etc.).
struct RecordedValueInvestmentLayout<Summary: View, ChartAndValuations: View, Transactions: View>:
  View
{
  private let summary: Summary
  private let chartAndValuations: ChartAndValuations
  private let transactions: Transactions

  init(
    @ViewBuilder summary: () -> Summary,
    @ViewBuilder chartAndValuations: () -> ChartAndValuations,
    @ViewBuilder transactions: () -> Transactions
  ) {
    self.summary = summary()
    self.chartAndValuations = chartAndValuations()
    self.transactions = transactions()
  }

  var body: some View {
    VStack(spacing: 0) {
      summary
      chartAndValuations
      Divider()
      transactions
    }
  }
}

#Preview {
  RecordedValueInvestmentLayout {
    Text("Performance Summary")
      .font(.headline)
      .padding()
  } chartAndValuations: {
    HStack(spacing: 0) {
      Text("Chart").frame(maxWidth: .infinity, maxHeight: 200).background(.quinary)
      Divider()
      Text("Valuations").frame(maxWidth: 200, maxHeight: 200).background(.quaternary)
    }
  } transactions: {
    List {
      ForEach(0..<5, id: \.self) { i in
        Text("Transaction \(i + 1)")
      }
    }
  }
}
