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
  var isTransfer: Bool {
    let accounts = Set(legs.filter { $0.type == .transfer }.compactMap(\.accountId))
    let instruments = Set(legs.filter { $0.type == .transfer }.map(\.instrument))
    return accounts.count > 1 || instruments.count > 1
  }

  // MARK: - Structure Queries

  /// Whether this transaction has simple structure: a single leg, or exactly
  /// two legs forming a basic transfer (amounts negate, same type, second leg
  /// has no category/earmark, and legs reference different accounts).
  var isSimple: Bool {
    if legs.count <= 1 { return true }
    guard legs.count == 2 else { return false }
    let a = legs[0]
    let b = legs[1]
    return a.quantity == -b.quantity
      && a.type == b.type
      && b.categoryId == nil
      && b.earmarkId == nil
      && a.accountId != b.accountId
  }

  /// Whether this transaction is a simple cross-currency transfer: exactly two
  /// transfer legs with different accounts and different instruments. Unlike
  /// `isSimple`, this does not require amounts to negate (since exchange rates
  /// mean the quantities will differ).
  var isSimpleCrossCurrencyTransfer: Bool {
    guard legs.count == 2 else { return false }
    let a = legs[0]
    let b = legs[1]
    guard a.type == .transfer && b.type == .transfer else { return false }
    guard let aAcct = a.accountId, let bAcct = b.accountId, aAcct != bAcct else { return false }
    guard b.categoryId == nil && b.earmarkId == nil else { return false }
    return a.instrument != b.instrument
  }
}

extension Array where Element: Hashable {
  /// Returns elements in order of first appearance, removing duplicates.
  func uniqued() -> [Element] {
    var seen = Set<Element>()
    return filter { seen.insert($0).inserted }
  }
}

// MARK: - Display Helpers

extension Transaction {
  /// Builds a display label for the transaction, handling transfers, earmarks, and payees.
  /// - Parameters:
  ///   - viewingAccountId: The account the user is viewing from (nil for scheduled/unfiltered views).
  ///   - accounts: Account lookup collection.
  ///   - earmarks: Earmark lookup collection.
  /// - Returns: A human-readable label for the transaction.
  func displayPayee(
    viewingAccountId: UUID?, accounts: Accounts, earmarks: Earmarks
  ) -> String {
    if isTransfer {
      if isSimple, let viewingAccountId,
        let otherLeg = legs.first(where: { $0.accountId != viewingAccountId })
      {
        // Account-scoped view: show direction relative to the viewer
        let otherAccountName =
          otherLeg.accountId.flatMap { accounts.by(id: $0) }?.name ?? "Unknown Account"
        let viewingLeg = legs.first(where: { $0.accountId == viewingAccountId })
        let isOutgoing = (viewingLeg?.quantity ?? 0) < 0
        let transferLabel =
          isOutgoing
          ? "Transfer to \(otherAccountName)"
          : "Transfer from \(otherAccountName)"

        if let payee, !payee.isEmpty {
          return "\(payee) (\(transferLabel))"
        }
        return transferLabel
      }

      // No account context (scheduled/upcoming): show "Transfer from A to B"
      let fromAccount = legs.first(where: { $0.quantity < 0 })?.accountId
      let toAccount = legs.first(where: { $0.quantity > 0 })?.accountId
      let fromName = fromAccount.flatMap { accounts.by(id: $0)?.name } ?? "Unknown"
      let toName = toAccount.flatMap { accounts.by(id: $0)?.name } ?? "Unknown"
      return "Transfer from \(fromName) to \(toName)"
    }

    if !isSimple {
      if let payee, !payee.isEmpty {
        return "\(payee) (\(legs.count) sub-transactions)"
      }
      return "\(legs.count) sub-transactions"
    }

    if let payee, !payee.isEmpty {
      return payee
    }

    let earmarkIds = legs.compactMap(\.earmarkId).uniqued()
    let earmarkNames = earmarkIds.compactMap { earmarks.by(id: $0)?.name }
    if !earmarkNames.isEmpty {
      return "Earmark funds for \(earmarkNames.joined(separator: ", "))"
    }

    return ""
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
  /// The instrument in which the running balance column should be displayed for
  /// this fetch. For account-scoped fetches this is the account's own instrument;
  /// for global fetches it's the profile instrument. Always populated — even when
  /// `priorBalance` is `nil` due to a conversion failure.
  let targetInstrument: Instrument
  /// Account balance before the oldest transaction in `transactions`. `nil` when
  /// the repository could not compute it (e.g. exchange-rate lookup failed). The
  /// transactions themselves are still returned so the list renders; running
  /// balances are just unavailable.
  let priorBalance: InstrumentAmount?
  let totalCount: Int?

  /// Computes the running balance after each transaction, converting each leg
  /// to the target instrument and computing a display amount per transaction.
  /// Transactions must be ordered newest-first (as returned by the repository).
  /// `priorBalance` is the account balance before the oldest transaction in the list.
  ///
  /// Graceful degradation: when a leg cannot be converted (e.g. exchange rate
  /// unavailable), that transaction is returned with `displayAmount == nil` and
  /// `balance == nil`, and every subsequent (newer) transaction also has
  /// `balance == nil` since the running total can no longer be tracked.
  /// The transactions themselves are always returned.
  static func withRunningBalances(
    transactions: [Transaction],
    priorBalance: InstrumentAmount?,
    accountId: UUID?,
    earmarkId: UUID? = nil,
    targetInstrument: Instrument,
    conversionService: InstrumentConversionService
  ) async -> [TransactionWithBalance] {
    var balance: InstrumentAmount? = priorBalance
    var result: [TransactionWithBalance] = []
    result.reserveCapacity(transactions.count)

    for transaction in transactions.reversed() {
      let convertedLegs: [ConvertedTransactionLeg]?
      do {
        var legs: [ConvertedTransactionLeg] = []
        legs.reserveCapacity(transaction.legs.count)
        for leg in transaction.legs {
          if leg.instrument == targetInstrument {
            legs.append(ConvertedTransactionLeg(leg: leg, convertedAmount: leg.amount))
          } else {
            let converted = try await conversionService.convertAmount(
              leg.amount, to: targetInstrument, on: transaction.date)
            legs.append(ConvertedTransactionLeg(leg: leg, convertedAmount: converted))
          }
        }
        convertedLegs = legs
      } catch {
        convertedLegs = nil
      }

      let displayAmount: InstrumentAmount?
      if let convertedLegs {
        if let accountId {
          displayAmount =
            convertedLegs
            .filter { $0.leg.accountId == accountId }
            .reduce(InstrumentAmount.zero(instrument: targetInstrument)) { $0 + $1.convertedAmount }
        } else if let earmarkId {
          // Earmark context (no account): sum legs matching the viewing earmark
          displayAmount =
            convertedLegs
            .filter { $0.leg.earmarkId == earmarkId }
            .reduce(InstrumentAmount.zero(instrument: targetInstrument)) { $0 + $1.convertedAmount }
        } else {
          // No account context (scheduled view): use negative-quantity leg for transfers,
          // otherwise sum all legs
          let isTransfer = transaction.legs.contains { $0.type == .transfer }
          if isTransfer {
            let negativeLeg = convertedLegs.first { $0.leg.quantity < 0 }
            displayAmount = negativeLeg?.convertedAmount ?? .zero(instrument: targetInstrument)
          } else {
            displayAmount =
              convertedLegs
              .reduce(InstrumentAmount.zero(instrument: targetInstrument)) {
                $0 + $1.convertedAmount
              }
          }
        }
      } else {
        displayAmount = nil
      }

      if let displayAmount, var runningBalance = balance {
        runningBalance += displayAmount
        balance = runningBalance
      } else {
        balance = nil
      }

      result.append(
        TransactionWithBalance(
          transaction: transaction,
          convertedLegs: convertedLegs ?? [],
          displayAmount: displayAmount,
          balance: balance
        ))
    }

    result.reverse()
    return result
  }
}

/// A transaction paired with converted leg amounts and the account balance after it was applied.
///
/// `displayAmount` and `balance` are `nil` when conversion failed — either for
/// this transaction's legs or for an earlier transaction in the running-balance
/// chain. `convertedLegs` is empty in the same case.
struct TransactionWithBalance: Sendable, Identifiable {
  let transaction: Transaction
  let convertedLegs: [ConvertedTransactionLeg]
  let displayAmount: InstrumentAmount?
  let balance: InstrumentAmount?

  var id: UUID { transaction.id }

  /// Returns converted legs belonging to the given account.
  func legs(forAccount accountId: UUID) -> [ConvertedTransactionLeg] {
    convertedLegs.filter { $0.leg.accountId == accountId }
  }

  /// Returns converted legs belonging to the given earmark.
  func legs(forEarmark earmarkId: UUID) -> [ConvertedTransactionLeg] {
    convertedLegs.filter { $0.leg.earmarkId == earmarkId }
  }
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
