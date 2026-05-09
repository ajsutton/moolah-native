// swiftlint:disable multiline_arguments

import SwiftUI

extension TransactionListView {
  /// Stable structural-branch guard: pins `transactionsList` to a fixed
  /// view-tree position so the asynchronous resolution of `positionsInput`
  /// can't flip the layout mid-load and cancel the initial transactions
  /// fetch. Same root cause as #412.
  var shouldShowPositionsSplit: Bool {
    guard !positions.isEmpty else { return false }
    let nonZeroInstruments = Set(
      positions.lazy.filter { $0.quantity != 0 }.map(\.instrument)
    )
    return nonZeroInstruments != [positionsHostCurrency]
  }

  @ViewBuilder var listView: some View {
    if shouldShowPositionsSplit {
      PositionsTransactionsSplit(defaultTab: .transactions) {
        if let positionsInput {
          PositionsView(input: positionsInput, range: $positionsRange)
        } else {
          ProgressView()
            .frame(maxWidth: .infinity)
            .padding()
        }
      } transactions: {
        transactionsList
      }
    } else {
      transactionsList
    }
  }

  private var transactionsList: some View {
    List(selection: selectedTransactionBinding) {
      listContent
    }
    #if os(macOS)
      .listStyle(.inset)
    #else
      .listStyle(.plain)
    #endif
    .accessibilityIdentifier(UITestIdentifiers.TransactionList.container)
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
        addToolbarButton
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
    .onChange(of: baseFilter) { _, newBase in
      // Genuine context change (e.g. user navigated from one account to
      // another): clear any stale selection and reset the user-applied
      // filter so the toolbar reflects the new context.
      selectedTransaction = nil
      activeFilter = newBase
    }
    .task(id: activeFilter) {
      // The view-driven reactive subscription. `observe(filter:)` runs
      // the for-await loop until this `.task` is cancelled (filter change
      // or unmount). The for-await body lives in the store, not here
      // (per the thin-view rule from spec Section 5).
      await transactionStore.observe(filter: activeFilter)
    }
    // Composite id: re-fire when the raw positions list changes, AND
    // when the registry version bumps (e.g. user marks a token as
    // `.spam`). Without the version dimension a spam flip in
    // preferences leaves a stale `valuedPositions` on screen until the
    // user navigates away and back. Issue #790.
    .task(id: PositionsTaskKey(positions: positions, registrationsVersion: registrationsVersion)) {
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
      // The valuator cooperates with cancellation by breaking out of
      // its per-row loop, but it cannot signal cancellation through the
      // non-throwing return — re-check here so a stale (or partial)
      // `rows` from a superseded task never overwrites the freshly-
      // emitting one.
      guard !Task.isCancelled else { return }
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

  /// The List content, branched on `grouping`. The `.flat` / `.byDate`
  /// cases render today's flat list; `.scheduledStatus` sections rows
  /// into Overdue / Upcoming via the store's pre-computed paths. Both
  /// branches share the surrounding modifier chain on `transactionsList`
  /// so future modifier additions don't have to be duplicated.
  @ViewBuilder private var listContent: some View {
    switch grouping {
    case .flat, .byDate:
      ForEach(filteredTransactions) { entry in
        transactionRow(for: entry)
      }
      loadMoreFooter
    case .scheduledStatus:
      let overdue = transactionStore.scheduledOverdueTransactions
      let upcoming = transactionStore.scheduledUpcomingTransactions
      if !overdue.isEmpty {
        Section("Overdue") {
          ForEach(overdue) { entry in
            transactionRow(for: entry)
          }
        }
      }
      if !upcoming.isEmpty {
        Section("Upcoming") {
          ForEach(upcoming) { entry in
            transactionRow(for: entry)
          }
        }
      }
    }
  }

  /// The toolbar's primary-action Add button. Branches on `grouping` so
  /// the `.scheduledStatus` mode shows "Add Scheduled Transaction" with a
  /// `calendar.badge.plus` icon and creates a recurring placeholder.
  @ViewBuilder private var addToolbarButton: some View {
    if case .scheduledStatus = grouping {
      Button {
        createNewScheduledTransaction()
      } label: {
        Label("Add Scheduled Transaction", systemImage: "calendar.badge.plus")
      }
    } else {
      Button {
        createNewTransaction()
      } label: {
        Label("Add Transaction", systemImage: "plus")
      }
    }
  }

  private var scopeReferenceInstrument: Instrument {
    if let accountId = filter.accountId, let account = accounts.by(id: accountId) {
      return account.instrument
    }
    if let earmarkId = filter.earmarkId, let earmark = earmarks.by(id: earmarkId) {
      return earmark.instrument
    }
    return positionsHostCurrency
  }

  @ViewBuilder
  private func transactionRow(for entry: TransactionWithBalance) -> some View {
    let scheduled = scheduledRowConfig(for: entry)
    TransactionRowView(
      transaction: entry.transaction, accounts: accounts,
      categories: categories, earmarks: earmarks, displayAmounts: entry.displayAmounts,
      balance: entry.balance, scopeReferenceInstrument: scopeReferenceInstrument,
      hideEarmark: filter.earmarkId != nil, viewingAccountId: filter.accountId,
      isOverdue: scheduled?.isOverdue ?? false,
      isDueToday: scheduled?.isDueToday ?? false,
      onPay: scheduled?.onPay,
      pendingPayId: scheduled?.pendingPayId
    )
    .tag(entry.transaction)
    .accessibilityIdentifier(
      UITestIdentifiers.TransactionList.transaction(entry.transaction.id)
    )
    .contentShape(Rectangle())
    .contextMenu { rowContextMenu(for: entry.transaction, isScheduled: scheduled != nil) }
    .swipeActions(edge: .trailing) {
      Button(role: .destructive) {
        transactionPendingDelete = entry.transaction.id
      } label: {
        Label("Delete Transaction", systemImage: "trash")
      }
    }
    .swipeActions(edge: .leading) {
      if let scheduled {
        Button {
          scheduled.onPay()
        } label: {
          Label("Pay Scheduled Transaction", systemImage: "checkmark.circle")
        }
        .tint(.green)
      }
    }
    .task {
      if entry.id == transactionStore.transactions.last?.id {
        await transactionStore.loadMore()
      }
    }
  }

  /// Per-row scheduled context. Returns `nil` for any non-scheduled
  /// grouping; the row then renders with all defaults (no overdue
  /// styling, no Pay button, no leading swipe). For `.scheduledStatus`,
  /// it computes the row's overdue / due-today flags against the store's
  /// pre-computed sectioning (so a row's section assignment and its
  /// `isOverdue` flag can never disagree) and exposes a typed Pay
  /// closure that writes the row id into the case's binding.
  private func scheduledRowConfig(for entry: TransactionWithBalance) -> ScheduledRowConfig? {
    guard case .scheduledStatus(let today, let pendingPayId) = grouping else {
      return nil
    }
    let overdueIds = Set(
      transactionStore.scheduledOverdueTransactions.map(\.transaction.id)
    )
    let isOverdue = overdueIds.contains(entry.transaction.id)
    let isDueToday =
      !isOverdue
      && Calendar.current.isDate(entry.transaction.date, inSameDayAs: today)
    return ScheduledRowConfig(
      isOverdue: isOverdue,
      isDueToday: isDueToday,
      pendingPayId: pendingPayId.wrappedValue,
      onPay: { pendingPayId.wrappedValue = entry.transaction.id }
    )
  }

  @ViewBuilder
  private func rowContextMenu(for transaction: Transaction, isScheduled: Bool) -> some View {
    if isScheduled, case .scheduledStatus(_, let pendingPayId) = grouping {
      Button("Pay Scheduled Transaction\u{2026}", systemImage: "checkmark.circle") {
        pendingPayId.wrappedValue = transaction.id
      }
    }
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

}

/// Per-row scheduled context bundle. Held as a `let` on the row so the
/// nil-vs-non-nil distinction (no scheduled context vs. scheduled
/// context) drives both the row's flags and the leading-swipe Pay
/// action — keeps the row's "is this a scheduled row" check on a
/// single source of truth.
private struct ScheduledRowConfig {
  let isOverdue: Bool
  let isDueToday: Bool
  let pendingPayId: Transaction.ID?
  let onPay: () -> Void
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

/// Composite id for the position-valuation `.task(id:)`. Rebuilds the
/// valued rows when either the raw positions list changes OR the
/// crypto registry version bumps (a `.spam` flip in preferences).
/// Issue #790.
private struct PositionsTaskKey: Hashable {
  let positions: [Position]
  let registrationsVersion: Int
}
