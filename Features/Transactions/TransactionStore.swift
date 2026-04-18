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
  private var currentFilter = TransactionFilter()
  private var currentPage = 0
  private var rawTransactions: [Transaction] = []
  private var priorBalance: InstrumentAmount? = nil

  init(
    repository: TransactionRepository,
    conversionService: InstrumentConversionService,
    targetInstrument: Instrument,
    pageSize: Int = 50,
    accountStore: AccountStore? = nil,
    earmarkStore: EarmarkStore? = nil
  ) {
    self.repository = repository
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

  /// Creates a default transaction with sensible defaults (expense, zero amount, today's date).
  /// Uses `accountId` if non-nil, otherwise falls back to `fallbackAccountId`.
  func createDefault(
    accountId: UUID?,
    fallbackAccountId: UUID?,
    instrument: Instrument
  ) async -> Transaction? {
    guard let acctId = accountId ?? fallbackAccountId else { return nil }
    let tx = Transaction(
      date: Date(),
      payee: "",
      legs: [TransactionLeg(accountId: acctId, instrument: instrument, quantity: 0, type: .expense)]
    )
    return await create(tx)
  }

  /// Creates a default earmark-only transaction (income type, zero amount, today's date).
  func createDefaultEarmark(
    earmarkId: UUID,
    instrument: Instrument
  ) async -> Transaction? {
    let tx = Transaction(
      date: Date(),
      payee: "",
      legs: [
        TransactionLeg(
          accountId: nil, instrument: instrument, quantity: 0, type: .income,
          earmarkId: earmarkId)
      ]
    )
    return await create(tx)
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
      applyBalanceDeltas(old: nil, new: created)
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
      applyBalanceDeltas(old: old, new: updated)
    } catch {
      logger.error("Failed to update transaction: \(error.localizedDescription)")
      rawTransactions = snapshot
      await recomputeBalances()
      self.error = error
    }
  }

  /// Pays a scheduled transaction: creates a non-scheduled copy with today's date,
  /// then either advances the scheduled transaction to its next due date (recurring)
  /// or deletes it (one-time). Reloads with the scheduled filter afterward.
  /// Returns the updated scheduled transaction if recurring, nil if deleted or failed.
  func payScheduledTransaction(_ scheduledTransaction: Transaction) async -> PayResult {
    isPayingScheduled = true
    defer { isPayingScheduled = false }
    // Create a non-scheduled copy with today's date
    let paidTransaction = Transaction(
      id: UUID(),
      date: Date(),
      payee: scheduledTransaction.payee,
      notes: scheduledTransaction.notes,
      legs: scheduledTransaction.legs
    )

    guard await create(paidTransaction) != nil else {
      return .failed
    }

    if scheduledTransaction.isRecurring, let nextDate = scheduledTransaction.nextDueDate() {
      var updated = scheduledTransaction
      updated.date = nextDate
      await update(updated)
    } else {
      await delete(id: scheduledTransaction.id)
    }

    // Remove the non-scheduled paid transaction from the local list
    // (it was added by create() but doesn't belong in the scheduled view).
    rawTransactions.removeAll { $0.id == paidTransaction.id }
    await recomputeBalances()

    if scheduledTransaction.isRecurring {
      let updated = transactions.first { $0.transaction.id == scheduledTransaction.id }?.transaction
      return .paid(updatedScheduledTransaction: updated)
    } else {
      return .deleted
    }
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
      applyBalanceDeltas(old: removed, new: nil)
    } catch {
      logger.error("Failed to delete transaction: \(error.localizedDescription)")
      rawTransactions = snapshot
      await recomputeBalances()
      self.error = error
    }
  }

  private func applyBalanceDeltas(old: Transaction?, new: Transaction?) {
    let delta = BalanceDeltaCalculator.deltas(old: old, new: new)
    if !delta.accountDeltas.isEmpty {
      accountStore?.applyDelta(delta.accountDeltas)
    }
    if !delta.earmarkDeltas.isEmpty || !delta.earmarkSavedDeltas.isEmpty
      || !delta.earmarkSpentDeltas.isEmpty
    {
      earmarkStore?.applyDelta(
        earmarkDeltas: delta.earmarkDeltas,
        savedDeltas: delta.earmarkSavedDeltas,
        spentDeltas: delta.earmarkSpentDeltas
      )
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

  // MARK: - Payee Suggestions

  private(set) var payeeSuggestions: [String] = []
  private var suggestionTask: Task<Void, Never>?

  func fetchPayeeSuggestions(prefix: String) {
    suggestionTask?.cancel()

    guard !prefix.isEmpty else {
      payeeSuggestions = []
      return
    }

    suggestionTask = Task {
      // Debounce: wait 200ms before firing
      try? await Task.sleep(nanoseconds: 200_000_000)
      guard !Task.isCancelled else { return }

      do {
        let suggestions = try await repository.fetchPayeeSuggestions(prefix: prefix)
        guard !Task.isCancelled else { return }
        payeeSuggestions = suggestions
      } catch {
        guard !Task.isCancelled else { return }
        logger.error("Failed to fetch payee suggestions: \(error.localizedDescription)")
        payeeSuggestions = []
      }
    }
  }

  func clearPayeeSuggestions() {
    suggestionTask?.cancel()
    payeeSuggestions = []
  }

  /// Fetch the most recent transaction matching a payee for auto-fill.
  func fetchTransactionForAutofill(payee: String) async -> Transaction? {
    do {
      let page = try await repository.fetch(
        filter: TransactionFilter(payee: payee),
        page: 0,
        pageSize: 1
      )
      return page.transactions.first
    } catch {
      logger.error("Failed to fetch autofill transaction: \(error.localizedDescription)")
      return nil
    }
  }

  // MARK: - Balance Computation

  private func recomputeBalances() async {
    // Re-sort newest-first to account for newly inserted/updated transactions
    rawTransactions.sort { a, b in
      if a.date != b.date { return a.date > b.date }
      return a.id.uuidString < b.id.uuidString
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
