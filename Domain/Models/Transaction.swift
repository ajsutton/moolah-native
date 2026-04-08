import Foundation

enum TransactionType: String, Codable, Sendable, CaseIterable {
  case income
  case expense
  case transfer
  case openingBalance

  /// Whether this transaction type can be manually created or edited by users.
  /// Opening balance transactions are system-generated and cannot be modified.
  var isUserEditable: Bool {
    self != .openingBalance
  }

  /// Display name for the transaction type
  var displayName: String {
    switch self {
    case .income: return "Income"
    case .expense: return "Expense"
    case .transfer: return "Transfer"
    case .openingBalance: return "Opening Balance"
    }
  }

  /// Only types that users can select when creating/editing transactions
  static var userSelectableTypes: [TransactionType] {
    [.income, .expense, .transfer]
  }
}

enum RecurPeriod: String, Codable, Sendable, CaseIterable {
  case once = "ONCE"
  case day = "DAY"
  case week = "WEEK"
  case month = "MONTH"
  case year = "YEAR"

  var displayName: String {
    switch self {
    case .once: return "Once"
    case .day: return "Day"
    case .week: return "Week"
    case .month: return "Month"
    case .year: return "Year"
    }
  }

  var pluralDisplayName: String {
    switch self {
    case .once: return "Once"
    case .day: return "Days"
    case .week: return "Weeks"
    case .month: return "Months"
    case .year: return "Years"
    }
  }
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
  var recurPeriod: RecurPeriod?
  var recurEvery: Int?

  var isScheduled: Bool {
    recurPeriod != nil
  }

  var isRecurring: Bool {
    guard let period = recurPeriod else { return false }
    return period != .once
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
    recurPeriod: RecurPeriod? = nil,
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
  var dateRange: ClosedRange<Date>?
  var categoryIds: Set<UUID>?
  var payee: String?

  init(
    accountId: UUID? = nil,
    earmarkId: UUID? = nil,
    scheduled: Bool? = nil,
    dateRange: ClosedRange<Date>? = nil,
    categoryIds: Set<UUID>? = nil,
    payee: String? = nil
  ) {
    self.accountId = accountId
    self.earmarkId = earmarkId
    self.scheduled = scheduled
    self.dateRange = dateRange
    self.categoryIds = categoryIds
    self.payee = payee
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

// MARK: - Recurrence Utilities

extension Transaction {
  /// Calculates the next due date for a recurring transaction.
  /// Returns nil if the transaction is not recurring (period is nil or .once).
  func nextDueDate() -> Date? {
    guard let period = recurPeriod, let every = recurEvery, period != .once else {
      return nil
    }

    let calendar = Calendar.current
    var components = DateComponents()

    switch period {
    case .day:
      components.day = every
    case .week:
      components.weekOfYear = every
    case .month:
      components.month = every
    case .year:
      components.year = every
    case .once:
      return nil
    }

    return calendar.date(byAdding: components, to: date)
  }

  /// Validates the transaction's recurrence fields.
  /// Throws an error if recurrence is partially configured (only period or only every is set).
  func validate() throws {
    // If either recurPeriod or recurEvery is set, both must be set
    if (recurPeriod != nil) != (recurEvery != nil) {
      throw ValidationError.incompleteRecurrence
    }

    // If recurring, recurEvery must be at least 1
    if let every = recurEvery, every < 1 {
      throw ValidationError.invalidRecurEvery
    }
  }

  enum ValidationError: LocalizedError {
    case incompleteRecurrence
    case invalidRecurEvery

    var errorDescription: String? {
      switch self {
      case .incompleteRecurrence:
        return "Recurrence must have both period and frequency set"
      case .invalidRecurEvery:
        return "Recurrence frequency must be at least 1"
      }
    }
  }
}
