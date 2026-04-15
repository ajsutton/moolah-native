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

extension RecurPeriod {
  /// Human-readable recurrence description, e.g. "Every month" or "Every 2 weeks".
  func recurrenceDescription(every: Int) -> String {
    guard self != .once else { return "" }
    let periodName = every == 1 ? displayName.lowercased() : pluralDisplayName.lowercased()
    return every == 1 ? "Every \(periodName)" : "Every \(every) \(periodName)"
  }
}

struct Transaction: Codable, Sendable, Identifiable, Hashable {
  let id: UUID
  var date: Date
  var payee: String?
  var notes: String?
  var recurPeriod: RecurPeriod?
  var recurEvery: Int?
  var legs: [TransactionLeg]

  var isScheduled: Bool {
    recurPeriod != nil
  }

  var isRecurring: Bool {
    guard let period = recurPeriod else { return false }
    return period != .once
  }

  init(
    id: UUID = UUID(),
    date: Date,
    payee: String? = nil,
    notes: String? = nil,
    recurPeriod: RecurPeriod? = nil,
    recurEvery: Int? = nil,
    legs: [TransactionLeg]
  ) {
    self.id = id
    self.date = date
    self.payee = payee
    self.notes = notes
    self.recurPeriod = recurPeriod
    self.recurEvery = recurEvery
    self.legs = legs
  }

  // MARK: - Convenience Accessors

  var accountIds: Set<UUID> { Set(legs.compactMap(\.accountId)) }
  var primaryAccountId: UUID? { legs.first?.accountId }
  var type: TransactionType { legs.first?.type ?? .expense }
  var categoryId: UUID? { legs.first?.categoryId }
  var earmarkId: UUID? { legs.first?.earmarkId }
  var primaryAmount: InstrumentAmount { legs.first?.amount ?? .zero(instrument: .AUD) }
  var isTransfer: Bool {
    let accounts = Set(legs.filter { $0.type == .transfer }.compactMap(\.accountId))
    let instruments = Set(legs.filter { $0.type == .transfer }.map(\.instrument))
    return accounts.count > 1 || instruments.count > 1
  }

  // MARK: - Structure Queries

  /// Whether this transaction has simple structure: a single leg, or exactly
  /// two legs forming a basic transfer (amounts negate, all other fields match).
  var isSimple: Bool {
    if legs.count <= 1 { return true }
    guard legs.count == 2 else { return false }
    let a = legs[0]
    let b = legs[1]
    return a.quantity == -b.quantity
      && a.type == b.type
      && a.categoryId == b.categoryId
      && a.earmarkId == b.earmarkId
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

extension TransactionFilter {
  var hasActiveFilters: Bool {
    accountId != nil || earmarkId != nil || scheduled != nil
      || dateRange != nil || categoryIds != nil || payee != nil
  }
}

/// A page of transactions returned from the repository, including the account
/// balance prior to the earliest transaction in this page.
struct TransactionPage: Sendable {
  let transactions: [Transaction]
  let priorBalance: InstrumentAmount
  let totalCount: Int?

  /// Computes the running balance after each transaction.
  /// Transactions must be ordered newest-first (as returned by the repository).
  /// `priorBalance` is the account balance before the oldest transaction in the list.
  static func withRunningBalances(
    transactions: [Transaction],
    priorBalance: InstrumentAmount
  ) -> [TransactionWithBalance] {
    // Walk oldest-to-newest accumulating the balance
    var balance = priorBalance
    var result: [TransactionWithBalance] = []
    result.reserveCapacity(transactions.count)

    for transaction in transactions.reversed() {
      balance += transaction.primaryAmount
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
  let balance: InstrumentAmount

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

  /// Validates the transaction's fields.
  func validate() throws {
    // If either recurPeriod or recurEvery is set, both must be set
    if (recurPeriod != nil) != (recurEvery != nil) {
      throw ValidationError.incompleteRecurrence
    }

    // If recurring, recurEvery must be at least 1
    if let every = recurEvery, every < 1 {
      throw ValidationError.invalidRecurEvery
    }

    if legs.isEmpty {
      throw ValidationError.noLegs
    }
  }

  enum ValidationError: LocalizedError {
    case incompleteRecurrence
    case invalidRecurEvery
    case noLegs

    var errorDescription: String? {
      switch self {
      case .incompleteRecurrence:
        return "Recurrence must have both period and frequency set"
      case .invalidRecurEvery:
        return "Recurrence frequency must be at least 1"
      case .noLegs:
        return "Transaction must have at least one leg"
      }
    }
  }
}
