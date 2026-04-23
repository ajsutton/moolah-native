import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class TransactionStore {
  private(set) var transactions: [TransactionWithBalance] = []
  private(set) var isLoading = false
  private(set) var hasMore = true
  private(set) var error: Error?
  private(set) var loadedCount = 0
  private(set) var totalCount: Int?
  /// True while a `payScheduledTransaction` call is in flight. Views observe
  /// this to show a progress indicator on the Pay button.
  private(set) var isPayingScheduled = false

  private let repository: TransactionRepository
  /// Owns the payee-autocomplete debounce/fetch state and the autofill
  /// lookup. Exposed directly so views bind through the dedicated type;
  /// `TransactionStore` no longer mirrors its surface.
  let payeeSuggestionSource: PayeeSuggestionSource
  private let conversionService: InstrumentConversionService
  /// The store's default target instrument (profile currency). Used for views
  /// that don't narrow to a single account — scheduled, upcoming, analysis.
  private(set) var targetInstrument: Instrument
  /// The instrument used for the currently-loaded view.
  /// Account-scoped views display balances in the account's own currency so
  /// native legs don't require conversion. The repository reports the
  /// account's instrument via `TransactionPage.targetInstrument`, and the
  /// store aligns to it on the first page fetch.
  private(set) var currentTargetInstrument: Instrument
  private let pageSize: Int
  private let accountStore: AccountStore?
  private let earmarkStore: EarmarkStore?
  private let logger = Logger(subsystem: "com.moolah.app", category: "TransactionStore")
  /// Filter that produced the current contents of `transactions`. Exposed so
  /// views sharing the store (Analysis, Upcoming) can ignore stale contents
  /// from a prior unfiltered load until their own `.task` reloads. When no
  /// load has completed yet, this is the default empty filter.
  private(set) var currentFilter = TransactionFilter()
  private var currentPage = 0
  private var rawTransactions: [Transaction] = []
  private var priorBalance: InstrumentAmount?

  init(
    repository: TransactionRepository,
    conversionService: InstrumentConversionService,
    targetInstrument: Instrument,
    pageSize: Int = 50,
    accountStore: AccountStore? = nil,
    earmarkStore: EarmarkStore? = nil
  ) {
    self.repository = repository
    self.payeeSuggestionSource = PayeeSuggestionSource(repository: repository)
    self.conversionService = conversionService
    self.targetInstrument = targetInstrument
    self.currentTargetInstrument = targetInstrument
    self.pageSize = pageSize
    self.accountStore = accountStore
    self.earmarkStore = earmarkStore
  }

  func load(filter: TransactionFilter) async {
    currentFilter = filter
    currentTargetInstrument = targetInstrument
    currentPage = 0
    rawTransactions = []
    priorBalance = nil
    transactions = []
    hasMore = true
    error = nil
    loadedCount = 0
    totalCount = nil
    await fetchPage()
  }

  func loadMore() async {
    guard !isLoading, hasMore else { return }
    await fetchPage()
  }

  // MARK: - Scheduled Views

  /// Scheduled transactions whose date is before today, sorted ascending by
  /// date. Empty when the store's current filter isn't `scheduled: true` —
  /// views sharing the store ignore stale contents from an unfiltered load
  /// in the frame before their own `.task` reloads the store.
  var scheduledOverdueTransactions: [TransactionWithBalance] {
    let today = Calendar.current.startOfDay(for: Date())
    return scheduledTransactions { $0 < today }
  }

  /// Scheduled transactions due today or later, sorted ascending by date.
  var scheduledUpcomingTransactions: [TransactionWithBalance] {
    let today = Calendar.current.startOfDay(for: Date())
    return scheduledTransactions { $0 >= today }
  }

  /// Scheduled transactions from the past plus the next `daysAhead` days —
  /// the set shown in the Analysis "Upcoming & Overdue" card.
  func scheduledShortTermTransactions(daysAhead: Int = 14) -> [TransactionWithBalance] {
    let ceiling = Calendar.current.date(byAdding: .day, value: daysAhead, to: Date()) ?? Date()
    return scheduledTransactions { $0 <= ceiling }
  }

  private func scheduledTransactions(
    where matches: (Date) -> Bool
  ) -> [TransactionWithBalance] {
    guard currentFilter.scheduled == true else { return [] }
    return
      transactions
      .filter { matches($0.transaction.date) }
      .sorted { $0.transaction.date < $1.transaction.date }
  }

  /// Creates a blank expense bound to `accountId` (falling back to
  /// `fallbackAccountId`). See `Transaction.defaultExpense(...)` for the shape.
  func createDefault(
    accountId: UUID?,
    fallbackAccountId: UUID?,
    instrument: Instrument
  ) async -> Transaction? {
    guard let acctId = accountId ?? fallbackAccountId else { return nil }
    return await create(.defaultExpense(accountId: acctId, instrument: instrument))
  }

  /// Creates a blank monthly-recurring expense. See
  /// `Transaction.defaultMonthlyScheduled(...)`.
  func createDefaultScheduled(
    accountId: UUID?,
    fallbackAccountId: UUID?,
    instrument: Instrument
  ) async -> Transaction? {
    guard let acctId = accountId ?? fallbackAccountId else { return nil }
    return await create(.defaultMonthlyScheduled(accountId: acctId, instrument: instrument))
  }

  /// Creates a blank earmark-only income transaction. See
  /// `Transaction.defaultEarmarkIncome(...)`.
  func createDefaultEarmark(
    earmarkId: UUID,
    instrument: Instrument
  ) async -> Transaction? {
    await create(.defaultEarmarkIncome(earmarkId: earmarkId, instrument: instrument))
  }

  func create(_ transaction: Transaction) async -> Transaction? {
    // Optimistic: insert into local state
    let snapshot = rawTransactions
    rawTransactions.append(transaction)
    await recomputeBalances()

    do {
      let created = try await repository.create(transaction)
      // Replace the optimistic entry with the server-confirmed one
      if let index = rawTransactions.firstIndex(where: { $0.id == transaction.id }) {
        rawTransactions[index] = created
      }
      await recomputeBalances()
      await applyBalanceDeltas(old: nil, new: created)
      return created
    } catch {
      logger.error("Failed to create transaction: \(error.localizedDescription)")
      rawTransactions = snapshot
      await recomputeBalances()
      self.error = error
      return nil
    }
  }

  func update(_ transaction: Transaction) async {
    // Optimistic: replace in local state
    let snapshot = rawTransactions
    let old = rawTransactions.first { $0.id == transaction.id }
    if let index = rawTransactions.firstIndex(where: { $0.id == transaction.id }) {
      rawTransactions[index] = transaction
      await recomputeBalances()
    }

    do {
      let updated = try await repository.update(transaction)
      if let index = rawTransactions.firstIndex(where: { $0.id == transaction.id }) {
        rawTransactions[index] = updated
      }
      await recomputeBalances()
      await applyBalanceDeltas(old: old, new: updated)
    } catch {
      logger.error("Failed to update transaction: \(error.localizedDescription)")
      rawTransactions = snapshot
      await recomputeBalances()
      self.error = error
    }
  }

  /// Records a payment of `scheduledTransaction`: creates a paid copy dated
  /// today, then either advances the scheduled template to its next due date
  /// (recurring) or deletes it (one-time). The paid copy is removed from
  /// local state because it doesn't belong in a scheduled-filtered view.
  func payScheduledTransaction(_ scheduledTransaction: Transaction) async -> PayResult {
    isPayingScheduled = true
    defer { isPayingScheduled = false }

    let paidTransaction = Transaction.paidCopy(of: scheduledTransaction)
    guard await create(paidTransaction) != nil else { return .failed }

    if let advanced = scheduledTransaction.advancingToNextDueDate() {
      await update(advanced)
    } else {
      await delete(id: scheduledTransaction.id)
    }

    rawTransactions.removeAll { $0.id == paidTransaction.id }
    await recomputeBalances()

    guard scheduledTransaction.isRecurring else { return .deleted }
    let updated = transactions.first { $0.transaction.id == scheduledTransaction.id }?.transaction
    return .paid(updatedScheduledTransaction: updated)
  }

  enum PayResult {
    case paid(updatedScheduledTransaction: Transaction?)
    case deleted
    case failed
  }

  func delete(id: UUID) async {
    // Optimistic: remove from local state
    let snapshot = rawTransactions
    let removed = rawTransactions.first { $0.id == id }
    rawTransactions.removeAll { $0.id == id }
    await recomputeBalances()

    do {
      try await repository.delete(id: id)
      await applyBalanceDeltas(old: removed, new: nil)
    } catch {
      logger.error("Failed to delete transaction: \(error.localizedDescription)")
      rawTransactions = snapshot
      await recomputeBalances()
      self.error = error
    }
  }

  private func applyBalanceDeltas(old: Transaction?, new: Transaction?) async {
    let delta = BalanceDeltaCalculator.deltas(old: old, new: new)
    if !delta.accountDeltas.isEmpty {
      await accountStore?.applyDelta(delta.accountDeltas)
    }
    if delta.hasEarmarkChanges {
      await earmarkStore?.applyDelta(
        earmarkDeltas: delta.earmarkDeltas,
        savedDeltas: delta.earmarkSavedDeltas,
        spentDeltas: delta.earmarkSpentDeltas)
    }
  }

  private func fetchPage() async {
    isLoading = true
    logger.debug("Loading transactions page \(self.currentPage)...")

    do {
      let page = try await repository.fetch(
        filter: currentFilter,
        page: currentPage,
        pageSize: pageSize
      )
      rawTransactions.append(contentsOf: page.transactions)
      priorBalance = page.priorBalance
      if currentPage == 0 {
        currentTargetInstrument = page.targetInstrument
      }
      hasMore = page.transactions.count >= pageSize
      currentPage += 1
      loadedCount = rawTransactions.count
      if let total = page.totalCount {
        totalCount = total
      }
      await recomputeBalances()
      logger.debug(
        "Loaded \(page.transactions.count) transactions (total: \(self.rawTransactions.count))")
    } catch {
      logger.error("Failed to load transactions: \(error.localizedDescription)")
      self.error = error
    }

    isLoading = false
  }

  // MARK: - Debounced Save

  private var saveTask: Task<Void, Never>?

  /// Debounces save calls: cancels any pending save, waits 300ms, then calls the callback.
  /// The callback is invoked on the main actor after the debounce delay.
  func debouncedSave(perform action: @escaping @MainActor () -> Void) {
    saveTask?.cancel()
    saveTask = Task {
      try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms debounce
      guard !Task.isCancelled else { return }
      action()
    }
  }

  // MARK: - Balance Computation

  private func recomputeBalances() async {
    // Re-sort newest-first to account for newly inserted/updated transactions
    rawTransactions.sort { lhs, rhs in
      if lhs.date != rhs.date { return lhs.date > rhs.date }
      return lhs.id.uuidString < rhs.id.uuidString
    }
    let result = await TransactionPage.withRunningBalances(
      transactions: rawTransactions,
      priorBalance: priorBalance,
      accountId: currentFilter.accountId,
      earmarkId: currentFilter.earmarkId,
      targetInstrument: currentTargetInstrument,
      conversionService: conversionService
    )
    transactions = result.rows
    // Surface conversion failures so the user sees a retryable error state
    // rather than silently blanked balances. Per Rule 11 of
    // `guides/INSTRUMENT_CONVERSION_GUIDE.md`, a failed conversion must be
    // logged and surfaced; the store logs here in addition to the per-leg log
    // emitted by `withRunningBalances`. If a prior recompute published a
    // conversion error and the current one succeeds, clear it so the UI
    // reflects recovery.
    if let conversionError = result.firstConversionError {
      logger.error(
        "Conversion failed while computing running balances: \(conversionError.localizedDescription)"
      )
      self.error = conversionError
    } else if self.error is RunningBalanceConversionError {
      self.error = nil
    }
  }
}
