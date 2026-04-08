import SwiftUI

enum SidebarSelection: Hashable {
  case account(UUID)
  case earmark(UUID)
  case allTransactions
  case upcomingTransactions
  case categories
}

struct SidebarView: View {
  @Environment(AccountStore.self) private var accountStore
  @Environment(EarmarkStore.self) private var earmarkStore
  @Binding var selection: SidebarSelection?
  @State private var showCreateEarmarkSheet = false
  @State private var showCreateAccountSheet = false
  @State private var accountToEdit: Account?
  #if os(iOS)
    @State private var editMode: EditMode = .inactive
  #endif

  var body: some View {
    List(selection: $selection) {
      Section {
        ForEach(accountStore.currentAccounts) { account in
          NavigationLink(value: SidebarSelection.account(account.id)) {
            AccountRowView(account: account)
          }
          .contextMenu {
            Button("Edit Account", systemImage: "pencil") {
              accountToEdit = account
            }
            Button("View Transactions", systemImage: "list.bullet") {
              selection = .account(account.id)
            }
          }
        }
        .onMove { source, destination in
          Task { await reorderCurrentAccounts(from: source, to: destination) }
        }

        totalRow(label: "Current Total", value: accountStore.currentTotal)
      } header: {
        HStack {
          Text("Current Accounts")
          Spacer()
          #if os(iOS)
            Button {
              showCreateAccountSheet = true
            } label: {
              Image(systemName: "plus")
                .font(.caption)
            }
            .buttonStyle(.plain)
          #endif
        }
      }

      if !earmarkStore.visibleEarmarks.isEmpty {
        Section {
          ForEach(earmarkStore.visibleEarmarks) { earmark in
            NavigationLink(value: SidebarSelection.earmark(earmark.id)) {
              EarmarkRowView(earmark: earmark)
            }
          }

          totalRow(label: "Earmarked Total", value: earmarkStore.totalBalance)
        } header: {
          HStack {
            Text("Earmarks")
            Spacer()
            #if os(iOS)
              Button {
                showCreateEarmarkSheet = true
              } label: {
                Image(systemName: "plus")
                  .font(.caption)
              }
              .buttonStyle(.plain)
            #endif
          }
        }
      }

      Section("Investments") {
        ForEach(accountStore.investmentAccounts) { account in
          NavigationLink(value: SidebarSelection.account(account.id)) {
            AccountRowView(account: account)
          }
          .contextMenu {
            Button("Edit Account", systemImage: "pencil") {
              accountToEdit = account
            }
            Button("View Transactions", systemImage: "list.bullet") {
              selection = .account(account.id)
            }
          }
        }
        .onMove { source, destination in
          Task { await reorderInvestmentAccounts(from: source, to: destination) }
        }

        totalRow(label: "Investment Total", value: accountStore.investmentTotal)
      }

      Section {
        LabeledContent("Available Funds") {
          MonetaryAmountView(amount: availableFunds)
        }
        .font(.headline)
        .accessibilityLabel(
          "Available Funds: \(availableFunds.decimalValue.formatted(.currency(code: availableFunds.currency.code)))"
        )

        LabeledContent("Net Worth") {
          MonetaryAmountView(amount: accountStore.netWorth)
        }
        .font(.headline)
        .bold()
        .accessibilityLabel(
          "Net Worth: \(accountStore.netWorth.decimalValue.formatted(.currency(code: accountStore.netWorth.currency.code)))"
        )
      }

      Section {
        NavigationLink(value: SidebarSelection.allTransactions) {
          Label("All Transactions", systemImage: "list.bullet")
        }

        NavigationLink(value: SidebarSelection.upcomingTransactions) {
          Label("Upcoming", systemImage: "calendar")
        }

        NavigationLink(value: SidebarSelection.categories) {
          Label("Categories", systemImage: "tag")
        }
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("Moolah")
    #if os(iOS)
      .environment(\.editMode, $editMode)
    #endif
    .refreshable {
      await accountStore.load()
      await earmarkStore.load()
    }
    #if os(macOS)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            showCreateAccountSheet = true
          } label: {
            Label("New Account", systemImage: "plus")
          }
          .help("Create new account")
        }
      }
    #endif
    .focusedSceneValue(\.newEarmarkAction) {
      showCreateEarmarkSheet = true
    }
    .sheet(isPresented: $showCreateEarmarkSheet) {
      CreateEarmarkSheet(
        onCreate: { newEarmark in
          Task {
            _ = await earmarkStore.create(newEarmark)
            showCreateEarmarkSheet = false
          }
        }
      )
    }
    .sheet(isPresented: $showCreateAccountSheet) {
      CreateAccountView(accountStore: accountStore)
    }
    .sheet(item: $accountToEdit) { account in
      EditAccountView(account: account, accountStore: accountStore)
    }
  }

  /// Current account total minus the sum of positive earmark balances.
  private var availableFunds: MonetaryAmount {
    let earmarked = earmarkStore.visibleEarmarks
      .filter { $0.balance.isPositive }
      .reduce(MonetaryAmount.zero) { $0 + $1.balance }
    return accountStore.currentTotal - earmarked
  }

  private func totalRow(label: String, value: MonetaryAmount) -> some View {
    LabeledContent(label) {
      MonetaryAmountView(amount: value, colorOverride: .secondary)
    }
    .foregroundStyle(.secondary)
    .font(.callout)
  }

  private func reorderCurrentAccounts(from source: IndexSet, to destination: Int) async {
    var accounts = accountStore.currentAccounts
    accounts.move(fromOffsets: source, toOffset: destination)

    // Update positions (0-indexed)
    for (index, account) in accounts.enumerated() {
      var updated = account
      updated.position = index
      _ = try? await accountStore.update(updated)
    }
  }

  private func reorderInvestmentAccounts(from source: IndexSet, to destination: Int) async {
    var accounts = accountStore.investmentAccounts
    accounts.move(fromOffsets: source, toOffset: destination)

    // Update positions (starting after current accounts)
    let offset = accountStore.currentAccounts.count
    for (index, account) in accounts.enumerated() {
      var updated = account
      updated.position = offset + index
      _ = try? await accountStore.update(updated)
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

#Preview {
  let backend = InMemoryBackend()
  let accountStore = AccountStore(repository: backend.accounts)
  let earmarkStore = EarmarkStore(repository: backend.earmarks)

  NavigationSplitView {
    SidebarView(selection: .constant(nil))
      .environment(accountStore)
      .environment(earmarkStore)
      .task {
        // Add some preview data
        _ = try? await backend.accounts.create(
          Account(
            name: "Bank", type: .bank,
            balance: MonetaryAmount(cents: 100000, currency: Currency.defaultCurrency)))
        _ = try? await backend.accounts.create(
          Account(
            name: "Asset", type: .asset,
            balance: MonetaryAmount(cents: 500000, currency: Currency.defaultCurrency)))
        _ = try? await backend.earmarks.create(
          Earmark(
            name: "Holiday Fund",
            balance: MonetaryAmount(cents: 150000, currency: Currency.defaultCurrency)))

        await accountStore.load()
        await earmarkStore.load()
      }
  } detail: {
    Text("Detail")
  }
}
