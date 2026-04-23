// swiftlint:disable multiline_arguments

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
  var supportsComplexTransactions: Bool = false

  /// When non-nil, the parent owns the selection and handles the inspector.
  /// When nil, TransactionListView manages its own selection and inspector.
  private let _externalSelection: Binding<Transaction?>?

  @State private var _internalSelection: Transaction?
  // Widened from `private` to module-internal so the file-scope extension in
  // `TransactionListView+List.swift` can read/mutate these from its
  // computed views and helpers. SwiftLint's `strict_fileprivate` rule
  // disallows `fileprivate`, making `internal` the smallest legal scope
  // when the helpers move to a sibling file.
  @State var activeFilter: TransactionFilter
  @State var showFilterSheet = false

  var filter: TransactionFilter { activeFilter }

  var displayTitle: String {
    if activeFilter != baseFilter {
      return "Filtered Transactions"
    }
    return title
  }

  var selectedTransaction: Transaction? {
    get { _externalSelection?.wrappedValue ?? _internalSelection }
    nonmutating set {
      if let ext = _externalSelection {
        ext.wrappedValue = newValue
      } else {
        _internalSelection = newValue
      }
    }
  }

  var selectedTransactionBinding: Binding<Transaction?> {
    if let ext = _externalSelection {
      return ext
    }
    return $_internalSelection
  }

  private var handlesOwnInspector: Bool { _externalSelection == nil }

  /// Default init — TransactionListView owns selection and shows its own inspector.
  init(
    title: String,
    filter: TransactionFilter,
    accounts: Accounts,
    categories: Categories,
    earmarks: Earmarks,
    transactionStore: TransactionStore,
    positions: [Position] = [],
    positionsHostCurrency: Instrument = .AUD,
    positionsTitle: String = "Balances",
    conversionService: (any InstrumentConversionService)? = nil,
    supportsComplexTransactions: Bool = false
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
    self.supportsComplexTransactions = supportsComplexTransactions
    self._externalSelection = nil
    self._activeFilter = State(initialValue: filter)
  }

  /// Embedded init — parent provides selection binding and handles the inspector.
  init(
    title: String,
    filter: TransactionFilter,
    accounts: Accounts,
    categories: Categories,
    earmarks: Earmarks,
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

  // See note above on `activeFilter`/`showFilterSheet`: widened from
  // `private` to module-internal so the file-scope extension in
  // `TransactionListView+List.swift` can bind to these.
  @State var positionsInput: PositionsViewInput?
  @State var positionsRange: PositionsTimeRange = .threeMonths

  @State private var showError = false
  @State private var errorMessage = ""
  @State var searchText = ""
  @FocusState private var searchFieldFocused: Bool
  @State var transactionPendingDelete: Transaction.ID?
  @State var createRuleFromTransaction: Transaction?

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
          viewingAccountId: filter.accountId,
          supportsComplexTransactions: supportsComplexTransactions
        )
      )
      .focusedSceneValue(\.newTransactionAction, createNewTransaction)
      .focusedSceneValue(\.findInListAction) { searchFieldFocused = true }
      .searchFocused($searchFieldFocused)
      // When the inspector opens, release our claim on the `.searchable`
      // first responder so focus can land on the detail view's payee/amount
      // field (set imperatively by `TransactionDetailView.task(id:)`).
      // Without this, AppKit's responder-chain fallback — reinforced after
      // a ⌘N menu event — would restore focus to the search field.
      .onChange(of: selectedTransaction) { _, new in
        if new != nil { searchFieldFocused = false }
      }
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
  private func ingestDroppedURLs(_ urls: [URL], forcedAccountId: UUID) async {
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

  func createNewTransaction() {
    let instrument = accounts.ordered.first?.instrument ?? .AUD

    // Build the placeholder with its own UUID and send that exact
    // transaction through `store.create`. CloudKit's repository echoes
    // the input transaction, so `selectedTransaction.id` stays stable
    // across the persist — the inspector's `.id(selected.id)` does not
    // force a view recreation and the detail view's focus state survives.
    let placeholder: Transaction?
    if let earmarkId = filter.earmarkId, filter.accountId == nil {
      placeholder = Transaction(
        date: Date(),
        payee: "",
        legs: [
          TransactionLeg(
            accountId: nil, instrument: instrument, quantity: 0, type: .income,
            earmarkId: earmarkId)
        ]
      )
    } else if let acctId = filter.accountId ?? accounts.ordered.first?.id {
      placeholder = Transaction(
        date: Date(),
        payee: "",
        legs: [
          TransactionLeg(accountId: acctId, instrument: instrument, quantity: 0, type: .expense)
        ]
      )
    } else {
      placeholder = nil
    }

    selectedTransaction = placeholder
    guard let placeholder else { return }
    Task {
      _ = await transactionStore.create(placeholder)
    }
  }

  var filteredTransactions: [TransactionWithBalance] {
    if searchText.isEmpty {
      return transactionStore.transactions
    }
    return transactionStore.transactions.filter {
      $0.transaction.payee?.localizedCaseInsensitiveContains(searchText) ?? false
    }
  }
}

@MainActor
private func seedTransactionListPreview(
  backend: CloudKitBackend,
  accountId: UUID,
  savingsId: UUID,
  store: TransactionStore
) async {
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
    targetInstrument: .AUD)
  return NavigationStack {
    TransactionListView(
      title: account.name, filter: TransactionFilter(accountId: accountId),
      accounts: accounts, categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: store)
  }
  .task {
    await seedTransactionListPreview(
      backend: backend, accountId: accountId, savingsId: savingsId, store: store)
  }
}
