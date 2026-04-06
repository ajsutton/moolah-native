import Foundation

actor InMemoryTransactionRepository: TransactionRepository {
    private var transactions: [UUID: Transaction]

    init(initialTransactions: [Transaction] = []) {
        self.transactions = Dictionary(uniqueKeysWithValues: initialTransactions.map { ($0.id, $0) })
    }

    func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> [Transaction] {
        var result = Array(transactions.values)

        // Filter by accountId (matches account_id OR to_account_id, like the server)
        if let accountId = filter.accountId {
            result = result.filter { $0.accountId == accountId || $0.toAccountId == accountId }
        }

        // Filter by scheduled
        if let scheduled = filter.scheduled {
            result = result.filter { $0.isScheduled == scheduled }
        }

        // Sort by date DESC, then id for stable ordering (matches server)
        result.sort { a, b in
            if a.date != b.date { return a.date > b.date }
            return a.id.uuidString < b.id.uuidString
        }

        // Paginate
        let offset = page * pageSize
        guard offset < result.count else { return [] }
        let end = min(offset + pageSize, result.count)
        return Array(result[offset..<end])
    }

    // For test setup
    func setTransactions(_ transactions: [Transaction]) {
        self.transactions = Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0) })
    }
}
