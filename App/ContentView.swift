import SwiftUI

/// Placeholder main content shown after sign-in. Replaced step-by-step with real screens.
struct ContentView: View {
  @Environment(AuthStore.self) private var authStore
  @Environment(AccountStore.self) private var accountStore
  @Environment(TransactionStore.self) private var transactionStore
  @Environment(CategoryStore.self) private var categoryStore
  @Environment(EarmarkStore.self) private var earmarkStore
  @State private var selection: SidebarSelection?

  @State private var showCreateEarmarkSheet = false

  var body: some View {
    NavigationSplitView {
      SidebarView(selection: $selection)
        .task {
          await accountStore.load()
          await categoryStore.load()
          await earmarkStore.load()
        }
        .toolbar {
          ToolbarItem(placement: .automatic) {
            if case .signedIn(let user) = authStore.state {
              UserMenuView(user: user)
                .environment(authStore)
            }
          }
        }
    } detail: {
      switch selection {
      case .account(let id):
        if let account = accountStore.accounts.by(id: id) {
          TransactionListView(
            title: account.name,
            filter: TransactionFilter(accountId: account.id),
            accounts: accountStore.accounts,
            categories: categoryStore.categories,
            earmarks: earmarkStore.earmarks,
            transactionStore: transactionStore)
        }
      case .earmark(let id):
        if let earmark = earmarkStore.earmarks.by(id: id) {
          EarmarkDetailView(
            earmark: earmark,
            accounts: accountStore.accounts,
            categories: categoryStore.categories,
            earmarks: earmarkStore.earmarks,
            transactionStore: transactionStore)
        }
      case .allTransactions:
        AllTransactionsView(
          accounts: accountStore.accounts,
          categories: categoryStore.categories,
          earmarks: earmarkStore.earmarks,
          transactionStore: transactionStore)
      case .upcomingTransactions:
        UpcomingView(
          accounts: accountStore.accounts,
          categories: categoryStore.categories,
          earmarks: earmarkStore.earmarks,
          transactionStore: transactionStore)
      case .categories:
        CategoriesView(categoryStore: categoryStore)
      case nil:
        Text("Select an account")
      }
    }
    .focusedSceneValue(\.newEarmarkAction) {
      showCreateEarmarkSheet = true
    }
    .sheet(isPresented: $showCreateEarmarkSheet) {
      CreateEarmarkSheet(
        onCreate: { newEarmark in
          Task {
            await earmarkStore.create(newEarmark)
            showCreateEarmarkSheet = false
          }
        }
      )
    }
  }
}

private struct CreateEarmarkSheet: View {
  let onCreate: (Earmark) -> Void

  @State private var name: String = ""
  @State private var savingsGoal: String = ""
  @State private var startDate: Date = Date()
  @State private var endDate: Date = Calendar.current.date(byAdding: .year, value: 1, to: Date())!
  @State private var useDateRange: Bool = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section("Details") {
          TextField("Name", text: $name)
        }

        Section("Savings Goal") {
          HStack {
            Text(Currency.defaultCurrency.code)
              .foregroundStyle(.secondary)
            TextField("Amount", text: $savingsGoal)
              #if os(iOS)
                .keyboardType(.decimalPad)
              #endif
          }

          Toggle("Set Date Range", isOn: $useDateRange)

          if useDateRange {
            DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
            DatePicker("End Date", selection: $endDate, displayedComponents: .date)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("New Earmark")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("Create") {
            createEarmark()
          }
          .disabled(name.isEmpty)
        }
      }
    }
  }

  private func createEarmark() {
    let goalCents = parseCurrency(savingsGoal)
    let goal =
      goalCents > 0 ? MonetaryAmount(cents: goalCents, currency: Currency.defaultCurrency) : nil

    let newEarmark = Earmark(
      name: name,
      savingsGoal: goal,
      savingsStartDate: useDateRange ? startDate : nil,
      savingsEndDate: useDateRange ? endDate : nil
    )
    onCreate(newEarmark)
  }

  private func parseCurrency(_ text: String) -> Int {
    let cleaned = text.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
    if let decimal = Decimal(string: cleaned) {
      return Int(truncating: (decimal * 100) as NSNumber)
    }
    return 0
  }
}
