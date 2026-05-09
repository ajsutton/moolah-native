import SwiftUI

/// Composition shell for the earmark detail screen.
///
/// Renders the standard earmark layout: an overview panel above a
/// segmented tab picker that switches between a transactions list and
/// a budget editor. Owns the `@State selectedTab` so the tab choice
/// survives across the leaf's renders.
///
/// **Content-only.** Per `guides/UI_GUIDE.md` §3, composition shells
/// must not register `.toolbar` or `.searchable` themselves —
/// `TransactionListView` (passed in via the `transactions` slot)
/// owns the searchable, and `EarmarkDetailView` (the leaf caller)
/// owns its own `.toolbar` (Edit) and `.transactionInspector`
/// modifiers at the leaf body level.
///
/// Outer `VStack(spacing: 0)`: per `guides/UI_GUIDE.md` §3.2 each
/// slot is responsible for its own internal padding.
struct EarmarkOverviewWithTabs<Overview: View, Transactions: View, Budget: View>: View {
  /// Named explicitly (not just `Tab`) to avoid shadowing SwiftUI's
  /// `Tab` type used with `TabView` on macOS 26 / iOS 26.
  private enum EarmarkTab: String, CaseIterable {
    case transactions = "Transactions"
    case budget = "Budget"
  }

  private let overview: Overview
  private let transactions: Transactions
  private let budget: Budget

  @State private var selectedTab: EarmarkTab = .transactions

  init(
    @ViewBuilder overview: () -> Overview,
    @ViewBuilder transactions: () -> Transactions,
    @ViewBuilder budget: () -> Budget
  ) {
    self.overview = overview()
    self.transactions = transactions()
    self.budget = budget()
  }

  var body: some View {
    VStack(spacing: 0) {
      overview
      Divider()

      Picker("View", selection: $selectedTab) {
        ForEach(EarmarkTab.allCases, id: \.self) { tab in
          Text(tab.rawValue).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal)
      .padding(.vertical, 8)

      switch selectedTab {
      case .transactions:
        transactions
      case .budget:
        budget
      }
    }
  }
}

#Preview {
  EarmarkOverviewWithTabs {
    VStack(spacing: 12) {
      Text("Overview Panel")
        .font(.headline)
      Text("Balance · Saved · Spent")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding()
  } transactions: {
    List {
      ForEach(0..<5, id: \.self) { i in
        Text("Transaction \(i + 1)")
      }
    }
  } budget: {
    List {
      ForEach(0..<3, id: \.self) { i in
        Text("Budget category \(i + 1)")
      }
    }
  }
}
