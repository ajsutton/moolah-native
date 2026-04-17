import SwiftData
import SwiftUI

struct TransactionListView: View {
  let title: String
  let baseFilter: TransactionFilter
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore
  var positions: [Position] = []

  /// When non-nil, the parent owns the selection and handles the inspector.
  /// When nil, TransactionListView manages its own selection and inspector.
  private let _externalSelection: Binding<Transaction?>?

  @State private var _internalSelection: Transaction?
  @State private var activeFilter: TransactionFilter
  @State private var showFilterSheet = false

  private var filter: TransactionFilter { activeFilter }

  private var displayTitle: String {
    if activeFilter != baseFilter {
      return "Filtered Transactions"
    }
    return title
  }

  private var selectedTransaction: Transaction? {
    get { _externalSelection?.wrappedValue ?? _internalSelection }
    nonmutating set {
      if let ext = _externalSelection {
        ext.wrappedValue = newValue
      } else {
        _internalSelection = newValue
      }
    }
  }

  private var selectedTransactionBinding: Binding<Transaction?> {
    if let ext = _externalSelection {
      return ext
    }
    return $_internalSelection
  }

  private var handlesOwnInspector: Bool { _externalSelection == nil }

  /// Default init — TransactionListView owns selection and shows its own inspector.
  init(
    title: String, filter: TransactionFilter,
    accounts: Accounts, categories: Categories, earmarks: Earmarks,
    transactionStore: TransactionStore,
    positions: [Position] = []
  ) {
    self.title = title
    self.baseFilter = filter
    self.accounts = accounts
    self.categories = categories
    self.earmarks = earmarks
    self.transactionStore = transactionStore
    self.positions = positions
    self._externalSelection = nil
    self._activeFilter = State(initialValue: filter)
  }

  /// Embedded init — parent provides selection binding and handles the inspector.
  init(
    title: String, filter: TransactionFilter,
    accounts: Accounts, categories: Categories, earmarks: Earmarks,
    transactionStore: TransactionStore,
    positions: [Position] = [],
    selectedTransaction: Binding<Transaction?>
  ) {
    self.title = title
    self.baseFilter = filter
    self.accounts = accounts
    self.categories = categories
    self.earmarks = earmarks
    self.transactionStore = transactionStore
    self.positions = positions
    self._externalSelection = selectedTransaction
    self._activeFilter = State(initialValue: filter)
  }

  @State private var showError = false
  @State private var errorMessage = ""
  @State private var searchText = ""

  var body: some View {
    listView
      .modifier(
        OptionalTransactionInspector(
          enabled: handlesOwnInspector,
          selectedTransaction: selectedTransactionBinding,
          accounts: accounts,
          categories: categories,
          earmarks: earmarks,
          transactionStore: transactionStore,
          viewingAccountId: filter.accountId
        )
      )
      .focusedSceneValue(\.newTransactionAction, createNewTransaction)
      .focusedSceneValue(\.selectedTransaction, selectedTransactionBinding)
      .alert("Error", isPresented: $showError) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage)
      }
      .task(id: transactionStore.error?.localizedDescription) {
        if let error = transactionStore.error {
          errorMessage = error.userMessage
          showError = true
        }
      }
  }

  private func createNewTransaction() {
    let instrument = accounts.ordered.first?.instrument ?? .AUD

    // When viewing from an earmark (no account in filter), create an earmark-only transaction
    if let earmarkId = filter.earmarkId, filter.accountId == nil {
      let placeholder = Transaction(
        date: Date(),
        payee: "",
        legs: [
          TransactionLeg(
            accountId: nil, instrument: instrument, quantity: 0, type: .income,
            earmarkId: earmarkId)
        ]
      )
      selectedTransaction = placeholder
      Task {
        if let created = await transactionStore.createDefaultEarmark(
          earmarkId: earmarkId,
          instrument: instrument
        ) {
          if selectedTransaction?.id == placeholder.id {
            selectedTransaction = created
          }
        }
      }
      return
    }

    let acctId = filter.accountId ?? accounts.ordered.first?.id

    // Create a placeholder for optimistic selection while the store creates it
    let placeholder: Transaction? = acctId.map { id in
      Transaction(
        date: Date(),
        payee: "",
        legs: [TransactionLeg(accountId: id, instrument: instrument, quantity: 0, type: .expense)]
      )
    }
    selectedTransaction = placeholder

    // Create the transaction in the store and update selection with server-confirmed version
    Task {
      if let created = await transactionStore.createDefault(
        accountId: filter.accountId,
        fallbackAccountId: accounts.ordered.first?.id,
        instrument: instrument
      ) {
        if selectedTransaction?.id == placeholder?.id {
          selectedTransaction = created
        }
      }
    }
  }

  private var filteredTransactions: [TransactionWithBalance] {
    if searchText.isEmpty {
      return transactionStore.transactions
    }
    return transactionStore.transactions.filter {
      $0.transaction.payee?.localizedCaseInsensitiveContains(searchText) ?? false
    }
  }

  private var listView: some View {
    List(selection: selectedTransactionBinding) {
      PositionListView(positions: positions)
      ForEach(filteredTransactions) { entry in
        TransactionRowView(
          transaction: entry.transaction, accounts: accounts,
          categories: categories, earmarks: earmarks, displayAmount: entry.displayAmount,
          balance: entry.balance, hideEarmark: filter.earmarkId != nil,
          viewingAccountId: filter.accountId
        )
        .tag(entry.transaction)
        .contentShape(Rectangle())
        .contextMenu {
          Button("Edit", systemImage: "pencil") {
            selectedTransaction = entry.transaction
          }
          Divider()
          Button("Delete", systemImage: "trash", role: .destructive) {
            Task {
              await transactionStore.delete(id: entry.transaction.id)
            }
          }
        }
        .swipeActions(edge: .trailing) {
          Button(role: .destructive) {
            Task {
              await transactionStore.delete(id: entry.transaction.id)
            }
          } label: {
            Label("Delete", systemImage: "trash")
          }
        }
        .onAppear {
          if entry.id == transactionStore.transactions.last?.id {
            Task {
              await transactionStore.loadMore()
            }
          }
        }
      }

      if transactionStore.isLoading {
        HStack {
          Spacer()
          if let total = transactionStore.totalCount, total > 0 {
            VStack(spacing: 4) {
              ProgressView(value: Double(transactionStore.loadedCount), total: Double(total))
                .frame(maxWidth: 200)
              Text("Loading \(transactionStore.loadedCount) of \(total)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
          } else {
            ProgressView()
          }
          Spacer()
        }
      }
    }
    #if os(macOS)
      .listStyle(.inset)
    #else
      .listStyle(.plain)
    #endif
    .profileNavigationTitle(displayTitle)
    .toolbar {
      ToolbarItem(placement: .automatic) {
        Button {
          showFilterSheet = true
        } label: {
          Label(
            "Filter",
            systemImage: activeFilter != baseFilter
              ? "line.3.horizontal.decrease.circle.fill"
              : "line.3.horizontal.decrease.circle")
        }
        .keyboardShortcut("f", modifiers: .command)
      }

      ToolbarItem(placement: .automatic) {
        Button {
          Task {
            await transactionStore.load(filter: filter)
          }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .keyboardShortcut("r", modifiers: .command)
      }

      ToolbarItem(placement: .primaryAction) {
        Button {
          createNewTransaction()
        } label: {
          Label("Add Transaction", systemImage: "plus")
        }
        .keyboardShortcut("n", modifiers: .command)
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
    .task(id: baseFilter) {
      // Reset filter and selection when switching accounts/contexts
      activeFilter = baseFilter
      selectedTransaction = nil
      await transactionStore.load(filter: baseFilter)
    }
    .task(id: activeFilter) {
      // Reload when user applies a filter
      if activeFilter != baseFilter {
        await transactionStore.load(filter: activeFilter)
      }
    }
    .refreshable {
      await transactionStore.load(filter: filter)
    }
    .searchable(text: $searchText, prompt: "Search payee")
    .overlay {
      if !transactionStore.isLoading && transactionStore.transactions.isEmpty {
        ContentUnavailableView(
          "No Transactions",
          systemImage: "tray",
          description: Text("No transactions found.")
        )
      }
    }
  }
}

#Preview {
  let accountId = UUID()
  let savingsId = UUID()
  let account = Account(
    id: accountId, name: "Checking", type: .bank, instrument: .AUD,
    positions: [Position(instrument: .AUD, quantity: 2449.77)])
  let accounts = Accounts(from: [
    account,
    Account(
      id: savingsId, name: "Savings", type: .bank, instrument: .AUD,
      positions: [Position(instrument: .AUD, quantity: 5000)]),
  ])
  let (backend, _) = PreviewBackend.create()
  let store = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD
  )

  NavigationStack {
    TransactionListView(
      title: account.name, filter: TransactionFilter(accountId: accountId),
      accounts: accounts, categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: store)
  }
  .task {
    _ = try? await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Woolworths",
        legs: [
          TransactionLeg(accountId: accountId, instrument: .AUD, quantity: -50.23, type: .expense)
        ]))
    _ = try? await backend.transactions.create(
      Transaction(
        date: Date().addingTimeInterval(-86400), payee: "Employer",
        legs: [
          TransactionLeg(accountId: accountId, instrument: .AUD, quantity: 3500, type: .income)
        ]))
    _ = try? await backend.transactions.create(
      Transaction(
        date: Date().addingTimeInterval(-172800),
        legs: [
          TransactionLeg(accountId: accountId, instrument: .AUD, quantity: -1000, type: .transfer),
          TransactionLeg(accountId: savingsId, instrument: .AUD, quantity: 1000, type: .transfer),
        ]))
    await store.load(filter: TransactionFilter(accountId: accountId))
  }
}
