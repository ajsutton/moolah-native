import Foundation

enum TransactionType: String, Codable, Sendable, CaseIterable {
  case income
  case expense
  case transfer
}

struct Transaction: Codable, Sendable, Identifiable, Hashable {
  let id: UUID
  var type: TransactionType
  var date: Date
  var accountId: UUID?
  var toAccountId: UUID?
  var amount: MonetaryAmount
  var payee: String?
  var notes: String?
  var categoryId: UUID?
  var earmarkId: UUID?
  var recurPeriod: String?  // DAY, WEEK, MONTH, YEAR
  var recurEvery: Int?

  var isScheduled: Bool {
    recurPeriod != nil
  }

  init(
    id: UUID = UUID(),
    type: TransactionType,
    date: Date,
    accountId: UUID? = nil,
    toAccountId: UUID? = nil,
    amount: MonetaryAmount,
    payee: String? = nil,
    notes: String? = nil,
    categoryId: UUID? = nil,
    earmarkId: UUID? = nil,
    recurPeriod: String? = nil,
    recurEvery: Int? = nil
  ) {
    self.id = id
    self.type = type
    self.date = date
    self.accountId = accountId
    self.toAccountId = toAccountId
    self.amount = amount
    self.payee = payee
    self.notes = notes
    self.categoryId = categoryId
    self.earmarkId = earmarkId
    self.recurPeriod = recurPeriod
    self.recurEvery = recurEvery
  }
}

struct TransactionFilter: Sendable, Equatable {
  var accountId: UUID?
  var earmarkId: UUID?
  var scheduled: Bool?

  init(accountId: UUID? = nil, earmarkId: UUID? = nil, scheduled: Bool? = nil) {
    self.accountId = accountId
    self.earmarkId = earmarkId
    self.scheduled = scheduled
  }
}

/// A page of transactions returned from the repository, including the account
/// balance prior to the earliest transaction in this page.
struct TransactionPage: Sendable {
  let transactions: [Transaction]
  let priorBalance: MonetaryAmount

  /// Computes the running balance after each transaction.
  /// Transactions must be ordered newest-first (as returned by the repository).
  /// `priorBalance` is the account balance before the oldest transaction in the list.
  static func withRunningBalances(
    transactions: [Transaction],
    priorBalance: MonetaryAmount
  ) -> [TransactionWithBalance] {
    // Walk oldest-to-newest accumulating the balance
    var balance = priorBalance
    var result: [TransactionWithBalance] = []
    result.reserveCapacity(transactions.count)

    for transaction in transactions.reversed() {
      balance += transaction.amount
      result.append(TransactionWithBalance(transaction: transaction, balance: balance))
    }

    // Reverse back to newest-first display order
    result.reverse()
    return result
  }
}

/// A transaction paired with the account balance after it was applied.
struct TransactionWithBalance: Sendable, Identifiable {
  let transaction: Transaction
  let balance: MonetaryAmount

  var id: UUID { transaction.id }
}
