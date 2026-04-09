import Foundation

actor InMemoryTransactionRepository: TransactionRepository {
  private var transactions: [UUID: Transaction]
  private let currency: Currency

  init(initialTransactions: [Transaction] = [], currency: Currency = .AUD) {
    self.transactions = Dictionary(uniqueKeysWithValues: initialTransactions.map { ($0.id, $0) })
    self.currency = currency
  }

  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage {
    var result = Array(transactions.values)

    // Filter by accountId (matches account_id OR to_account_id, like the server)
    if let accountId = filter.accountId {
      result = result.filter { $0.accountId == accountId || $0.toAccountId == accountId }
    }

    // Filter by earmarkId
    if let earmarkId = filter.earmarkId {
      result = result.filter { $0.earmarkId == earmarkId }
    }

    // Filter by scheduled
    if let scheduled = filter.scheduled {
      result = result.filter { $0.isScheduled == scheduled }
    }

    // Filter by date range
    if let dateRange = filter.dateRange {
      result = result.filter { dateRange.contains($0.date) }
    }

    // Filter by categoryIds
    if let categoryIds = filter.categoryIds, !categoryIds.isEmpty {
      result = result.filter { transaction in
        guard let categoryId = transaction.categoryId else { return false }
        return categoryIds.contains(categoryId)
      }
    }

    // Filter by payee (case-insensitive contains)
    if let payee = filter.payee, !payee.isEmpty {
      let lowered = payee.lowercased()
      result = result.filter { transaction in
        guard let transactionPayee = transaction.payee else { return false }
        return transactionPayee.lowercased().contains(lowered)
      }
    }

    // Sort by date DESC, then id for stable ordering (matches server)
    result.sort { a, b in
      if a.date != b.date { return a.date > b.date }
      return a.id.uuidString < b.id.uuidString
    }

    // Paginate
    let offset = page * pageSize
    guard offset < result.count else {
      return TransactionPage(
        transactions: [], priorBalance: MonetaryAmount(cents: 0, currency: currency))
    }
    let end = min(offset + pageSize, result.count)
    let pageTransactions = Array(result[offset..<end])

    // priorBalance = sum of all transactions older than this page
    let priorBalance = result[end...].reduce(MonetaryAmount(cents: 0, currency: currency)) {
      $0 + $1.amount
    }

    return TransactionPage(transactions: pageTransactions, priorBalance: priorBalance)
  }

  func create(_ transaction: Transaction) async throws -> Transaction {
    transactions[transaction.id] = transaction
    return transaction
  }

  func update(_ transaction: Transaction) async throws -> Transaction {
    guard transactions[transaction.id] != nil else {
      throw BackendError.serverError(404)
    }
    transactions[transaction.id] = transaction
    return transaction
  }

  func delete(id: UUID) async throws {
    guard transactions.removeValue(forKey: id) != nil else {
      throw BackendError.serverError(404)
    }
  }

  func fetchPayeeSuggestions(prefix: String) async throws -> [String] {
    guard !prefix.isEmpty else { return [] }
    let lowered = prefix.lowercased()
    let matching = transactions.values
      .compactMap(\.payee)
      .filter { !$0.isEmpty && $0.lowercased().hasPrefix(lowered) }
    // Count frequency of each payee and sort most-used first
    var counts: [String: Int] = [:]
    for payee in matching {
      counts[payee, default: 0] += 1
    }
    return counts.sorted { $0.value > $1.value }.map(\.key)
  }

  // For test setup
  func setTransactions(_ transactions: [Transaction]) {
    self.transactions = Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0) })
  }
}
