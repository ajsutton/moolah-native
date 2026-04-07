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

  func create(_ transaction: Transaction) async {
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
    } catch {
      logger.error("Failed to create transaction: \(error.localizedDescription)")
      rawTransactions = snapshot
      recomputeBalances()
      self.error = error
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
