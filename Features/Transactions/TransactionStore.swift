import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class TransactionStore {
  private(set) var transactions: [Transaction] = []
  private(set) var isLoading = false
  private(set) var hasMore = true
  private(set) var error: Error?

  private let repository: TransactionRepository
  private let pageSize: Int
  private let logger = Logger(subsystem: "com.moolah.app", category: "TransactionStore")
  private var currentFilter = TransactionFilter()
  private var currentPage = 0

  init(repository: TransactionRepository, pageSize: Int = 50) {
    self.repository = repository
    self.pageSize = pageSize
  }

  func load(filter: TransactionFilter) async {
    currentFilter = filter
    currentPage = 0
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
      transactions.append(contentsOf: page)
      hasMore = page.count >= pageSize
      currentPage += 1
      logger.debug("Loaded \(page.count) transactions (total: \(self.transactions.count))")
    } catch {
      logger.error("Failed to load transactions: \(error.localizedDescription)")
      self.error = error
    }

    isLoading = false
  }
}
