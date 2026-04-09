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

  /// Called after a successful create, update, or delete so the caller
  /// can adjust account balances locally.
  /// Parameters: (old transaction or nil, new transaction or nil).
  var onMutate: (@MainActor (_ old: Transaction?, _ new: Transaction?) -> Void)?

  private let repository: TransactionRepository
  private let pageSize: Int
  private let logger = Logger(subsystem: "com.moolah.app", category: "TransactionStore")
  private var currentFilter = TransactionFilter()
  private var currentPage = 0
  private var rawTransactions: [Transaction] = []
  private var priorBalance: MonetaryAmount = .zero

  init(repository: TransactionRepository, pageSize: Int = 50) {
    self.repository = repository
    self.pageSize = pageSize
  }

  func load(filter: TransactionFilter) async {
    currentFilter = filter
    currentPage = 0
    rawTransactions = []
    priorBalance = .zero
    transactions = []
    hasMore = true
    error = nil
    await fetchPage()
  }

  func loadMore() async {
    guard !isLoading, hasMore else { return }
    await fetchPage()
  }

  func create(_ transaction: Transaction) async -> Transaction? {
    // Optimistic: insert into local state
    let snapshot = rawTransactions
    rawTransactions.append(transaction)
    recomputeBalances()

    do {
      let created = try await repository.create(transaction)
      // Replace the optimistic entry with the server-confirmed one
      if let index = rawTransactions.firstIndex(where: { $0.id == transaction.id }) {
        rawTransactions[index] = created
      }
      recomputeBalances()
      onMutate?(nil, created)
      return created
    } catch {
      logger.error("Failed to create transaction: \(error.localizedDescription)")
      rawTransactions = snapshot
      recomputeBalances()
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
      recomputeBalances()
    }

    do {
      let updated = try await repository.update(transaction)
      if let index = rawTransactions.firstIndex(where: { $0.id == transaction.id }) {
        rawTransactions[index] = updated
      }
      recomputeBalances()
      onMutate?(old, updated)
    } catch {
      logger.error("Failed to update transaction: \(error.localizedDescription)")
      rawTransactions = snapshot
      recomputeBalances()
      self.error = error
    }
  }

  /// Pays a scheduled transaction: creates a non-scheduled copy with today's date,
  /// then either advances the scheduled transaction to its next due date (recurring)
  /// or deletes it (one-time). Reloads with the scheduled filter afterward.
  /// Returns the updated scheduled transaction if recurring, nil if deleted or failed.
  func payScheduledTransaction(_ scheduledTransaction: Transaction) async -> PayResult {
    // Create a non-scheduled copy with today's date
    let paidTransaction = Transaction(
      id: UUID(),
      type: scheduledTransaction.type,
      date: Date(),
      accountId: scheduledTransaction.accountId,
      toAccountId: scheduledTransaction.toAccountId,
      amount: scheduledTransaction.amount,
      payee: scheduledTransaction.payee,
      notes: scheduledTransaction.notes,
      categoryId: scheduledTransaction.categoryId,
      earmarkId: scheduledTransaction.earmarkId,
      recurPeriod: nil,
      recurEvery: nil
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

    await load(filter: TransactionFilter(scheduled: true))

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
    recomputeBalances()

    do {
      try await repository.delete(id: id)
      onMutate?(removed, nil)
    } catch {
      logger.error("Failed to delete transaction: \(error.localizedDescription)")
      rawTransactions = snapshot
      recomputeBalances()
      self.error = error
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
      hasMore = page.transactions.count >= pageSize
      currentPage += 1
      recomputeBalances()
      logger.debug(
        "Loaded \(page.transactions.count) transactions (total: \(self.rawTransactions.count))")
    } catch {
      logger.error("Failed to load transactions: \(error.localizedDescription)")
      self.error = error
    }

    isLoading = false
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

  private func recomputeBalances() {
    // Re-sort newest-first to account for newly inserted/updated transactions
    rawTransactions.sort { a, b in
      if a.date != b.date { return a.date > b.date }
      return a.id.uuidString < b.id.uuidString
    }
    transactions = TransactionPage.withRunningBalances(
      transactions: rawTransactions,
      priorBalance: priorBalance
    )
  }
}
