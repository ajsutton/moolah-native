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
      transactions = TransactionPage.withRunningBalances(
        transactions: rawTransactions,
        priorBalance: priorBalance
      )
      logger.debug(
        "Loaded \(page.transactions.count) transactions (total: \(self.rawTransactions.count))")
    } catch {
      logger.error("Failed to load transactions: \(error.localizedDescription)")
      self.error = error
    }

    isLoading = false
  }
}
