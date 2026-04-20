import SwiftData
import SwiftUI

struct TransactionListView: View {
  let title: String
  let baseFilter: TransactionFilter
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore
  @Environment(ImportStore.self) private var importStore
  var positions: [Position] = []
  var positionsHostCurrency: Instrument = .AUD
  var positionsTitle: String = "Balances"
  var conversionService: (any InstrumentConversionService)?

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
    positions: [Position] = [],
    positionsHostCurrency: Instrument = .AUD,
    positionsTitle: String = "Balances",
    conversionService: (any InstrumentConversionService)? = nil
  ) {
    self.title = title
    self.baseFilter = filter
    self.accounts = accounts
    self.categories = categories
    self.earmarks = earmarks
    self.transactionStore = transactionStore
    self.positions = positions
    self.positionsHostCurrency = positionsHostCurrency
    self.positionsTitle = positionsTitle
    self.conversionService = conversionService
    self._externalSelection = nil
    self._activeFilter = State(initialValue: filter)
  }

  /// Embedded init — parent provides selection binding and handles the inspector.
  init(
    title: String, filter: TransactionFilter,
    accounts: Accounts, categories: Categories, earmarks: Earmarks,
    transactionStore: TransactionStore,
    positions: [Position] = [],
    positionsHostCurrency: Instrument = .AUD,
    positionsTitle: String = "Balances",
    conversionService: (any InstrumentConversionService)? = nil,
    selectedTransaction: Binding<Transaction?>
  ) {
    self.title = title
    self.baseFilter = filter
    self.accounts = accounts
    self.categories = categories
    self.earmarks = earmarks
    self.transactionStore = transactionStore
    self.positions = positions
    self.positionsHostCurrency = positionsHostCurrency
    self.positionsTitle = positionsTitle
    self.conversionService = conversionService
    self._externalSelection = selectedTransaction
    self._activeFilter = State(initialValue: filter)
  }

  @State private var positionsInput: PositionsViewInput?
  @State private var positionsRange: PositionsTimeRange = .threeMonths

  @State private var showError = false
  @State private var errorMessage = ""
  @State private var searchText = ""
  @FocusState private var searchFieldFocused: Bool
  @State private var transactionPendingDelete: Transaction.ID?
  @State private var createRuleFromTransaction: Transaction?

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
      .focusedSceneValue(\.findInListAction) { searchFieldFocused = true }
      .searchFocused($searchFieldFocused)
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
      .confirmationDialog(
        "Delete this transaction?",
        isPresented: Binding(
          get: { transactionPendingDelete != nil },
          set: { if !$0 { transactionPendingDelete = nil } }
        ),
        titleVisibility: .visible
      ) {
        Button("Delete Transaction", role: .destructive) {
          if let id = transactionPendingDelete {
            Task { await transactionStore.delete(id: id) }
          }
          transactionPendingDelete = nil
        }
        Button("Cancel", role: .cancel) { transactionPendingDelete = nil }
      } message: {
        Text("This action cannot be undone.")
      }
      .onReceive(NotificationCenter.default.publisher(for: .requestTransactionEdit)) { note in
        guard let id = note.object as? Transaction.ID,
          let entry = filteredTransactions.first(where: { $0.transaction.id == id })
        else { return }
        selectedTransaction = entry.transaction
      }
      .onReceive(NotificationCenter.default.publisher(for: .requestTransactionDelete)) { note in
        guard let id = note.object as? Transaction.ID,
          filteredTransactions.contains(where: { $0.transaction.id == id })
        else { return }
        transactionPendingDelete = id
      }
      .modifier(
        TransactionListCSVImportAddons(
          createRuleFromTransaction: $createRuleFromTransaction,
          corpusProvider: {
            transactionStore.transactions.compactMap {
              $0.transaction.importOrigin?.rawDescription
            }
          },
          forcedAccountId: filter.accountId,
          ingestDroppedURLs: ingestDroppedURLs))
  }

  /// Mirror of `RecentlyAddedView.ingestDroppedURLs` but with a forced
  /// account. Kept here so the view can hand off to `ImportStore`
  /// directly; logic is intentionally minimal (security-scope → read
  /// bytes → ingest).
  fileprivate func ingestDroppedURLs(_ urls: [URL], forcedAccountId: UUID) async {
    for url in urls {
      guard url.pathExtension.lowercased() == "csv" || url.pathExtension.isEmpty else {
        continue
      }
      let didStart = url.startAccessingSecurityScopedResource()
      defer {
        if didStart { url.stopAccessingSecurityScopedResource() }
      }
      guard let data = try? Data(contentsOf: url) else { continue }
      _ = await importStore.ingest(
        data: data,
        source: .droppedFile(url: url, forcedAccountId: forcedAccountId))
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
    VStack(spacing: 0) {
      if let positionsInput, !positionsInput.positions.isEmpty {
        PositionsView(input: positionsInput, range: $positionsRange)
        Divider()
      }
      List(selection: selectedTransactionBinding) {
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
            Button("Edit Transaction\u{2026}", systemImage: "pencil") {
              selectedTransaction = entry.transaction
            }
            // Only offer "Create rule from this…" for CSV-imported rows —
            // ImportOrigin is how we extract distinguishing tokens, and
            // manually-entered transactions don't have one.
            if entry.transaction.importOrigin != nil {
              Button("Create rule from this\u{2026}", systemImage: "plus.rectangle.on.folder") {
                createRuleFromTransaction = entry.transaction
              }
            }
            Divider()
            Button("Delete Transaction\u{2026}", systemImage: "trash", role: .destructive) {
              transactionPendingDelete = entry.transaction.id
            }
          }
          .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
              transactionPendingDelete = entry.transaction.id
            } label: {
              Label("Delete Transaction", systemImage: "trash")
            }
          }
          .task {
            if entry.id == transactionStore.transactions.last?.id {
              await transactionStore.loadMore()
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
        }

        ToolbarItem(placement: .automatic) {
          Button {
            Task {
              await transactionStore.load(
                filter: filter)
            }
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
        }

        ToolbarItem(placement: .primaryAction) {
          Button {
            createNewTransaction()
          } label: {
            Label("Add Transaction", systemImage: "plus")
          }
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
        await transactionStore.load(
          filter: baseFilter)
      }
      .task(id: activeFilter) {
        // Reload when user applies a filter
        if activeFilter != baseFilter {
          await transactionStore.load(
            filter: activeFilter)
        }
      }
      .task(id: positions) {
        guard let conversionService, !positions.isEmpty else {
          positionsInput = nil
          return
        }
        let valuator = PositionsValuator(conversionService: conversionService)
        let rows = await valuator.valuate(
          positions: positions,
          hostCurrency: positionsHostCurrency,
          costBasis: [:],
          on: Date()
        )
        positionsInput = PositionsViewInput(
          title: positionsTitle,
          hostCurrency: positionsHostCurrency,
          positions: rows,
          historicalValue: nil
        )
      }
      .refreshable {
        await transactionStore.load(
          filter: filter)
      }
      .searchable(text: $searchText, prompt: "Search payee")
      .overlay {
        emptyStateOverlay
      }
    }
  }

  /// Empty-state overlay, differentiated by context:
  /// - Active search with no matches → system search empty state.
  /// - Loaded transactions exist but none match the current (filter + search) → hint to
  ///   clear filters/search.
  /// - No transactions loaded at all with an active filter → filter excludes everything.
  /// - Otherwise (new / empty account) → encourage adding the first transaction.
  @ViewBuilder
  private var emptyStateOverlay: some View {
    if transactionStore.isLoading {
      EmptyView()
    } else if filteredTransactions.isEmpty {
      let hasSearch = !searchText.isEmpty
      let hasFilter = activeFilter != baseFilter
      let hasAnyLoaded = !transactionStore.transactions.isEmpty

      if hasSearch && hasAnyLoaded {
        // Some transactions are loaded; the search is narrowing them to zero.
        ContentUnavailableView.search(text: searchText)
      } else if hasFilter {
        ContentUnavailableView {
          Label("No Matches", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
          Text("No transactions match the current filter.")
        } actions: {
          Button("Clear Filter") {
            activeFilter = baseFilter
          }
        }
      } else if hasSearch {
        // No transactions are loaded at all, but a search term is present.
        ContentUnavailableView.search(text: searchText)
      } else {
        ContentUnavailableView(
          "No Transactions",
          systemImage: "tray",
          description: Text(
            PlatformActionVerb.emptyStatePrompt(
              buttonLabel: "+",
              suffix: "to add your first transaction."
            )
          )
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

/// Groups the CSV-import-specific modifiers (create-rule sheet + drop
/// target) so the main `body` chain stays within the Swift type checker's
/// complexity budget. Extracting a modifier was the minimal change that
/// kept these affordances without triggering a `too complex` compile
/// error on the long `.onReceive` / `.sheet` chain.
private struct TransactionListCSVImportAddons: ViewModifier {
  @Binding var createRuleFromTransaction: Transaction?
  let corpusProvider: () -> [String]
  let forcedAccountId: UUID?
  let ingestDroppedURLs: (_ urls: [URL], _ forcedAccountId: UUID) async -> Void

  func body(content: Content) -> some View {
    content
      .sheet(item: $createRuleFromTransaction) { tx in
        CreateRuleFromTransactionSheet(
          transaction: tx,
          corpus: corpusProvider())
      }
      .dropDestination(for: URL.self) { urls, _ in
        guard let accountId = forcedAccountId else { return false }
        Task { await ingestDroppedURLs(urls, accountId) }
        return !urls.isEmpty
      }
  }
}
