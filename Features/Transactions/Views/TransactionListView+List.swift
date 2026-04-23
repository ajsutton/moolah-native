import SwiftUI

extension TransactionListView {
  @ViewBuilder var listView: some View {
    if let positionsInput, !positionsInput.positions.isEmpty {
      PositionsTransactionsSplit(defaultTab: .transactions) {
        PositionsView(input: positionsInput, range: $positionsRange)
      } transactions: {
        transactionsList
      }
    } else {
      transactionsList
    }
  }

  private var transactionsList: some View {
    List(selection: selectedTransactionBinding) {
      ForEach(filteredTransactions) { entry in
        transactionRow(for: entry)
      }
      loadMoreFooter
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

  @ViewBuilder
  private func transactionRow(for entry: TransactionWithBalance) -> some View {
    TransactionRowView(
      transaction: entry.transaction, accounts: accounts,
      categories: categories, earmarks: earmarks, displayAmount: entry.displayAmount,
      balance: entry.balance, hideEarmark: filter.earmarkId != nil,
      viewingAccountId: filter.accountId
    )
    .tag(entry.transaction)
    .accessibilityIdentifier(
      UITestIdentifiers.TransactionList.transaction(entry.transaction.id)
    )
    .contentShape(Rectangle())
    .contextMenu { rowContextMenu(for: entry.transaction) }
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

  @ViewBuilder
  private func rowContextMenu(for transaction: Transaction) -> some View {
    Button("Edit Transaction\u{2026}", systemImage: "pencil") {
      selectedTransaction = transaction
    }
    // Only offer "Create rule from this…" for CSV-imported rows —
    // ImportOrigin is how we extract distinguishing tokens, and
    // manually-entered transactions don't have one.
    if transaction.importOrigin != nil {
      Button("Create rule from this\u{2026}", systemImage: "plus.rectangle.on.folder") {
        createRuleFromTransaction = transaction
      }
    }
    Divider()
    Button("Delete Transaction\u{2026}", systemImage: "trash", role: .destructive) {
      transactionPendingDelete = transaction.id
    }
  }

  @ViewBuilder private var loadMoreFooter: some View {
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

  /// Empty-state overlay, differentiated by context:
  /// - Active search with no matches → system search empty state.
  /// - Loaded transactions exist but none match the current (filter + search) → hint to
  ///   clear filters/search.
  /// - No transactions loaded at all with an active filter → filter excludes everything.
  /// - Otherwise (new / empty account) → encourage adding the first transaction.
  @ViewBuilder private var emptyStateOverlay: some View {
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

/// Groups the CSV-import-specific modifiers (create-rule sheet + drop
/// target) so the main `body` chain stays within the Swift type checker's
/// complexity budget. Extracting a modifier was the minimal change that
/// kept these affordances without triggering a `too complex` compile
/// error on the long `.onReceive` / `.sheet` chain.
struct TransactionListCSVImportAddons: ViewModifier {
  @Binding var createRuleFromTransaction: Transaction?
  let corpusProvider: () -> [String]
  let forcedAccountId: UUID?
  let ingestDroppedURLs: (_ urls: [URL], _ forcedAccountId: UUID) async -> Void

  func body(content: Content) -> some View {
    content
      .sheet(item: $createRuleFromTransaction) { transaction in
        CreateRuleFromTransactionSheet(
          transaction: transaction,
          corpus: corpusProvider())
      }
      .dropDestination(for: URL.self) { urls, _ in
        guard let accountId = forcedAccountId else { return false }
        Task { await ingestDroppedURLs(urls, accountId) }
        return !urls.isEmpty
      }
  }
}
