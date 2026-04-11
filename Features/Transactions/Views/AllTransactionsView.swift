import SwiftData
import SwiftUI

struct AllTransactionsView: View {
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore

  @State private var activeFilter = TransactionFilter()
  @State private var showFilterSheet = false

  var body: some View {
    TransactionListView(
      title: filterTitle,
      filter: activeFilter,
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore
    )
    .toolbar {
      ToolbarItem(placement: .automatic) {
        Button {
          showFilterSheet = true
        } label: {
          Label(
            "Filter",
            systemImage: hasActiveFilters
              ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .keyboardShortcut("f", modifiers: .command)
      }
    }
    .sheet(isPresented: $showFilterSheet) {
      TransactionFilterView(
        filter: activeFilter,
        accounts: accounts,
        categories: categories,
        earmarks: earmarks,
        onApply: { newFilter in
          activeFilter = newFilter
          showFilterSheet = false
        }
      )
    }
  }

  private var filterTitle: String {
    if hasActiveFilters {
      return "Filtered Transactions"
    } else {
      return "All Transactions"
    }
  }

  private var hasActiveFilters: Bool {
    activeFilter.accountId != nil || activeFilter.earmarkId != nil || activeFilter.scheduled != nil
      || activeFilter.dateRange != nil || activeFilter.categoryIds != nil
      || activeFilter.payee != nil
  }
}

#Preview {
  let accountId = UUID()
  let categoryId = UUID()
  let earmarkId = UUID()

  let accounts = Accounts(from: [
    Account(
      id: accountId, name: "Checking", type: .bank,
      balance: MonetaryAmount(cents: 244977, currency: Currency.AUD)
    )
  ])

  let categories = Categories(from: [
    Category(id: categoryId, name: "Groceries", parentId: nil)
  ])

  let earmarks = Earmarks(from: [
    Earmark(
      id: earmarkId, name: "Emergency Fund",
      balance: MonetaryAmount(cents: 100000, currency: Currency.AUD)
    )
  ])

  let (backend, _, _) = PreviewBackend.create()
  let store = TransactionStore(repository: backend.transactions)

  NavigationStack {
    AllTransactionsView(
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: store
    )
  }
  .task {
    _ = try? await backend.transactions.create(
      Transaction(
        type: .expense, date: Date(), accountId: accountId,
        amount: MonetaryAmount(cents: -5023, currency: Currency.AUD),
        payee: "Woolworths", categoryId: categoryId))
    await store.load(filter: TransactionFilter())
  }
}
