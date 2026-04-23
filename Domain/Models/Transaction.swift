import Foundation
import OSLog

private let transactionLogger = Logger(
  subsystem: "com.moolah.app", category: "Transaction.withRunningBalances")

struct Transaction: Codable, Sendable, Identifiable, Hashable {
  let id: UUID
  var date: Date
  var payee: String?
  var notes: String?
  var recurPeriod: RecurPeriod?
  var recurEvery: Int?
  var legs: [TransactionLeg]
  var importOrigin: ImportOrigin?

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
    legs: [TransactionLeg],
    importOrigin: ImportOrigin? = nil
  ) {
    self.id = id
    self.date = date
    self.payee = payee
    self.notes = notes
    self.recurPeriod = recurPeriod
    self.recurEvery = recurEvery
    self.legs = legs
    self.importOrigin = importOrigin
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
    let first = legs[0]
    let second = legs[1]
    return first.quantity == -second.quantity
      && first.type == second.type
      && second.categoryId == nil
      && second.earmarkId == nil
      && first.accountId != second.accountId
  }

  /// Whether this transaction is a simple cross-currency transfer: exactly two
  /// transfer legs with different accounts and different instruments. Unlike
  /// `isSimple`, this does not require amounts to negate (since exchange rates
  /// mean the quantities will differ).
  var isSimpleCrossCurrencyTransfer: Bool {
    guard legs.count == 2 else { return false }
    let first = legs[0]
    let second = legs[1]
    guard first.type == .transfer && second.type == .transfer else { return false }
    guard let firstAcct = first.accountId, let secondAcct = second.accountId,
      firstAcct != secondAcct
    else { return false }
    guard second.categoryId == nil && second.earmarkId == nil else { return false }
    return first.instrument != second.instrument
  }
}

struct TransactionFilter: Sendable, Equatable {
  var accountId: UUID?
  var earmarkId: UUID?
  var scheduled: Bool?
  var dateRange: ClosedRange<Date>?
  var categoryIds: Set<UUID>
  var payee: String?

  init(
    accountId: UUID? = nil,
    earmarkId: UUID? = nil,
    scheduled: Bool? = nil,
    dateRange: ClosedRange<Date>? = nil,
    categoryIds: Set<UUID> = [],
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
      || dateRange != nil || !categoryIds.isEmpty || payee != nil
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
  ///
  /// The result also carries the first conversion error encountered (if any) so
  /// callers can surface a retryable error state to the user. Per Rule 11 of
  /// `guides/INSTRUMENT_CONVERSION_GUIDE.md`, every failure is logged via
  /// `os.Logger` at `warning` level, not silently swallowed.
  static func withRunningBalances(
    transactions: [Transaction],
    priorBalance: InstrumentAmount?,
    accountId: UUID?,
    earmarkId: UUID? = nil,
    targetInstrument: Instrument,
    conversionService: InstrumentConversionService
  ) async -> RunningBalanceResult {
    var balance: InstrumentAmount? = priorBalance
    var result: [TransactionWithBalance] = []
    result.reserveCapacity(transactions.count)
    var firstConversionError: RunningBalanceConversionError?

    for transaction in transactions.reversed() {
      let conversion = await convertLegs(
        for: transaction,
        targetInstrument: targetInstrument,
        conversionService: conversionService)
      switch conversion {
      case .success(let convertedLegs):
        let displayAmount = computeDisplayAmount(
          for: transaction,
          convertedLegs: convertedLegs,
          accountId: accountId,
          earmarkId: earmarkId,
          targetInstrument: targetInstrument)
        if let displayAmount, var runningBalance = balance {
          runningBalance += displayAmount
          balance = runningBalance
        }
        result.append(
          TransactionWithBalance(
            transaction: transaction,
            convertedLegs: convertedLegs,
            displayAmount: displayAmount,
            balance: balance))
      case .failure(let error):
        if firstConversionError == nil {
          firstConversionError = error
        }
        balance = nil
        result.append(
          TransactionWithBalance(
            transaction: transaction,
            convertedLegs: [],
            displayAmount: nil,
            balance: nil))
      }
    }

    result.reverse()
    return RunningBalanceResult(
      rows: result,
      firstConversionError: firstConversionError
    )
  }

  private enum LegConversion {
    case success([ConvertedTransactionLeg])
    case failure(RunningBalanceConversionError)
  }

  /// Convert every leg of `transaction` into `targetInstrument`. Returns
  /// `.failure` on the first leg that cannot be converted so callers can
  /// mark the running balance unavailable from that row onward.
  private static func convertLegs(
    for transaction: Transaction,
    targetInstrument: Instrument,
    conversionService: InstrumentConversionService
  ) async -> LegConversion {
    var legs: [ConvertedTransactionLeg] = []
    legs.reserveCapacity(transaction.legs.count)
    do {
      for leg in transaction.legs {
        if leg.instrument == targetInstrument {
          legs.append(ConvertedTransactionLeg(leg: leg, convertedAmount: leg.amount))
        } else {
          let converted = try await conversionService.convertAmount(
            leg.amount, to: targetInstrument, on: transaction.date)
          legs.append(ConvertedTransactionLeg(leg: leg, convertedAmount: converted))
        }
      }
      return .success(legs)
    } catch {
      transactionLogger.warning(
        """
        Failed to convert leg to \(targetInstrument.id, privacy: .public) for transaction \
        \(transaction.id, privacy: .public) on \(transaction.date, privacy: .public): \
        \(error.localizedDescription, privacy: .public). Running balance will be unavailable \
        from this point.
        """)
      return .failure(
        RunningBalanceConversionError(
          transactionId: transaction.id,
          targetInstrumentId: targetInstrument.id,
          underlyingDescription: error.localizedDescription))
    }
  }

  /// Picks the amount to display on a row: per-account sum when viewing an
  /// account, per-earmark sum when viewing an earmark, otherwise transfers
  /// show the negative-quantity leg and non-transfers sum all legs.
  private static func computeDisplayAmount(
    for transaction: Transaction,
    convertedLegs: [ConvertedTransactionLeg],
    accountId: UUID?,
    earmarkId: UUID?,
    targetInstrument: Instrument
  ) -> InstrumentAmount? {
    let zero = InstrumentAmount.zero(instrument: targetInstrument)
    if let accountId {
      return
        convertedLegs
        .filter { $0.leg.accountId == accountId }
        .reduce(zero) { $0 + $1.convertedAmount }
    }
    if let earmarkId {
      return
        convertedLegs
        .filter { $0.leg.earmarkId == earmarkId }
        .reduce(zero) { $0 + $1.convertedAmount }
    }
    // Scheduled view (no account context): transfers show the negative
    // leg; everything else sums all legs.
    let isTransfer = transaction.legs.contains { $0.type == .transfer }
    if isTransfer {
      let negativeLeg = convertedLegs.first { $0.leg.quantity < 0 }
      return negativeLeg?.convertedAmount ?? zero
    }
    return convertedLegs.reduce(zero) { $0 + $1.convertedAmount }
  }
}
