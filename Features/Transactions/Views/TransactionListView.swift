import SwiftUI

struct TransactionListView: View {
  /// Grouping for the rendered list. Default `.flat` keeps existing
  /// callers unchanged. `.scheduledStatus` bundles a `pendingPayId`
  /// binding that the row's Pay action writes into; the binding is
  /// structurally required when the caller selects that case (no
  /// `Binding<>` defaults to silently-discarding `.constant(nil)`).
  ///
  /// Grouping is @MainActor-only; do not add Sendable conformance —
  /// `Binding<T>`'s closures are MainActor-isolated.
  enum Grouping {
    case flat
    case scheduledStatus(today: Date, pendingPayId: Binding<Transaction.ID?>)
  }

  let title: String
  let baseFilter: TransactionFilter
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore
  let grouping: Grouping
  @Environment(ImportStore.self) private var importStore

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

  init(
    title: String,
    filter: TransactionFilter,
    accounts: Accounts,
    categories: Categories,
    earmarks: Earmarks,
    transactionStore: TransactionStore,
    grouping: Grouping = .flat
  ) {
    self.title = title
    self.baseFilter = filter
    self.accounts = accounts
    self.categories = categories
    self.earmarks = earmarks
    self.transactionStore = transactionStore
    self.grouping = grouping
    self._externalSelection = nil
    self._activeFilter = State(initialValue: filter)
  }

  /// Embedded init — parent provides selection binding and handles the
  /// inspector. Used by `InvestmentAccountView` and `EarmarkDetailView` so
  /// their leaf-owned `@State selectedTransaction` survives inner-leaf
  /// `.id(...)` tear-downs.
  init(
    title: String,
    filter: TransactionFilter,
    accounts: Accounts,
    categories: Categories,
    earmarks: Earmarks,
    transactionStore: TransactionStore,
    grouping: Grouping = .flat,
    selectedTransaction: Binding<Transaction?>
  ) {
    self.title = title
    self.baseFilter = filter
    self.accounts = accounts
    self.categories = categories
    self.earmarks = earmarks
    self.transactionStore = transactionStore
    self.grouping = grouping
    self._externalSelection = selectedTransaction
    self._activeFilter = State(initialValue: filter)
  }

  @State private var showError = false
  @State private var errorMessage = ""
  @State var searchText = ""
  @FocusState private var searchFieldFocused: Bool
  @State var transactionPendingDelete: Transaction.ID?
  @State var createRuleFromTransaction: Transaction?

  var body: some View {
    transactionsList
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
      .focusedSceneValue(\.newTransactionAction, newTransactionAction)
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
      .focusedSceneValue(
        \.editTransactionAction,
        selectedTransaction != nil
          ? {
            // Discoverability affordance: under the current architecture
            // dismissing the inspector clears `selectedTransaction` (see
            // `TransactionInspectorModifier.isPresented`), so this action is
            // only published when the inspector is already open and the
            // self-assign is a no-op. The menu item exists so users can
            // discover that Edit is available without right-clicking the row.
            // If the inspector ever stops clearing selection on dismissal,
            // this self-assign needs to become an explicit reopen path.
            selectedTransaction = selectedTransaction
          }
          : nil
      )
      .focusedSceneValue(
        \.deleteTransactionAction,
        selectedTransaction != nil
          ? { transactionPendingDelete = selectedTransaction?.id }
          : nil
      )
      .alert("Error", isPresented: $showError) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage)
      }
      .task(id: transactionStore.error?.localizedDescription) {
        // Re-fires whenever the store's error description changes — including
        // the X → nil transition that follows a successful retry. Without the
        // `else` branch a stale `showError = true` would survive the error
        // being cleared by the next `load()`, latching the alert on every
        // subsequent mount.
        if let error = transactionStore.error {
          errorMessage = error.userMessage
          showError = true
        } else {
          showError = false
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
  ///
  /// `ImportStore` writes via `backend.transactions.create(_:)`. The
  /// view's reactive subscription on `transactionStore.observe(filter:)`
  /// will see the writes via `repository.observe(...)` and refresh the
  /// list automatically — no explicit reload is needed here.
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

  var filteredTransactions: [TransactionWithBalance] {
    if searchText.isEmpty {
      return transactionStore.transactions
    }
    return transactionStore.transactions.filter {
      $0.transaction.payee?.localizedCaseInsensitiveContains(searchText) ?? false
    }
  }
}
