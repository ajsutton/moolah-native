// swiftlint:disable multiline_arguments

import Foundation

// `PositionsViewInput` assembly + trade-based cost-basis snapshotting
// extracted from the main `InvestmentStore` body so it stays under
// SwiftLint's `type_body_length` threshold.
extension InvestmentStore {
  // MARK: - PositionsView Input

  /// Builds the `PositionsViewInput` for the unified positions UI. Reads
  /// from the already-loaded `valuedPositions` for the row data, replays
  /// trade transactions through the shared `TradeEventClassifier` +
  /// `CostBasisEngine` to derive a per-instrument cost-basis snapshot, and
  /// asks `PositionsHistoryBuilder` for the chart series.
  ///
  /// Caller-supplied `title` lets the host pass the account name (or any
  /// embedding-appropriate label).
  func positionsViewInput(
    title: String,
    range: PositionsTimeRange
  ) async -> PositionsViewInput {
    guard let transactionRepository else {
      let hostCurrency = loadedHostCurrency ?? .AUD
      return PositionsViewInput(
        title: title,
        hostCurrency: hostCurrency,
        positions: valuedPositions,
        historicalValue: nil,
        performance: accountPerformance)
    }

    let txns: [Transaction]
    do {
      txns = try await fetchAllTransactions(
        repository: transactionRepository,
        accountId: loadedAccountId ?? UUID())
    } catch {
      logger.warning(
        "fetchAllTransactions failed, cost basis will be empty: \(error.localizedDescription, privacy: .public)"
      )
      txns = []
    }
    let hostCurrency = loadedHostCurrency ?? valuedPositions.first?.value?.instrument ?? .AUD
    let costSnapshot = await costBasisSnapshot(
      transactions: txns, hostCurrency: hostCurrency)
    let rowsWithCost: [ValuedPosition] = valuedPositions.map { row in
      ValuedPosition(
        instrument: row.instrument,
        quantity: row.quantity,
        unitPrice: row.unitPrice,
        costBasis: costSnapshot[row.instrument.id].map {
          InstrumentAmount(quantity: $0, instrument: hostCurrency)
        },
        value: row.value
      )
    }

    let series = await PositionsHistoryBuilder(conversionService: conversionService).build(
      transactions: txns,
      accountId: loadedAccountId ?? UUID(),
      hostCurrency: hostCurrency,
      range: range
    )

    return PositionsViewInput(
      title: title,
      hostCurrency: hostCurrency,
      positions: rowsWithCost,
      historicalValue: series,
      performance: accountPerformance)
  }

  func fetchAllTransactions(
    repository: TransactionRepository,
    accountId: UUID
  ) async throws -> [Transaction] {
    var all: [Transaction] = []
    var page = 0
    while true {
      let result = try await repository.fetch(
        filter: TransactionFilter(accountId: accountId),
        page: page, pageSize: 200
      )
      guard !Task.isCancelled else { return all }
      all.append(contentsOf: result.transactions)
      if result.transactions.count < 200 { break }
      page += 1
    }
    return all
  }

  /// Annualized return rate as a percentage, computed via binary search.
  /// Ported from InvestmentValue.vue:168-235.
  func annualizedReturnRate(currentValue: InstrumentAmount) -> Double {
    guard !dailyBalances.isEmpty, !values.isEmpty else { return 0 }

    // Get the most recent value date (values are sorted descending)
    guard let latestValue = values.first else { return 0 }
    let targetValue = Double(truncating: currentValue.quantity as NSDecimalNumber)
    let balanceValues = dailyBalances.map {
      BalancePoint(
        date: $0.date,
        balance: Double(truncating: $0.balance.quantity as NSDecimalNumber))
    }

    guard let firstBalance = balanceValues.first, firstBalance.balance != 0 else { return 0 }

    let futureValue: (Double) -> Double = { rate in
      Self.futureValue(
        atMonthlyRate: rate,
        balanceValues: balanceValues,
        finalDate: latestValue.date)
    }

    switch Self.bracketReturnRate(target: targetValue, futureValue: futureValue) {
    case .overflowHigh: return .infinity
    case .overflowLow: return -.infinity
    case .bracket(let bounds):
      let converged = Self.binarySearchReturnRate(
        target: targetValue, initial: bounds, futureValue: futureValue)
      return (converged ?? (bounds.high + bounds.low) / 2) * 100
    }
  }

  private struct BalancePoint {
    let date: Date
    let balance: Double
  }

  private struct RateBracket {
    var low: Double
    var high: Double
  }

  private enum BracketResult {
    case bracket(RateBracket)
    case overflowHigh
    case overflowLow
  }

  /// Replays cash flows through a candidate monthly rate to get the
  /// projected value at `finalDate`.
  private static func futureValue(
    atMonthlyRate rate: Double,
    balanceValues: [BalancePoint],
    finalDate: Date
  ) -> Double {
    var prevBalance = balanceValues[0].balance
    var val = prevBalance
    var date = balanceValues[0].date

    for i in 1...balanceValues.count {
      let nextDate = i < balanceValues.count ? balanceValues[i].date : finalDate
      let nextBalance = i < balanceValues.count ? balanceValues[i].balance : prevBalance
      let days = Calendar.current.dateComponents([.day], from: date, to: nextDate).day ?? 0
      guard days > 0 else { continue }

      let interest = val * pow(1 + rate / 12, Double(days) / 30)
      val = interest + (nextBalance - prevBalance)
      prevBalance = nextBalance
      date = nextDate
    }
    return val
  }

  /// Grows the bracket `[low, high]` outward until `futureValue(low) <
  /// target < futureValue(high)`. Returns `.overflowHigh` / `.overflowLow`
  /// when the return exceeds the sanity cap in the respective direction —
  /// the caller maps those to `+/- .infinity`.
  private static func bracketReturnRate(
    target: Double,
    futureValue: (Double) -> Double
  ) -> BracketResult {
    var bracket = RateBracket(low: -1.0, high: 1.0)
    while futureValue(bracket.high) < target {
      bracket.high *= 2
      if bracket.high > 1000 { return .overflowHigh }
    }
    while futureValue(bracket.low) > target {
      bracket.low *= 2
      if bracket.low < -1000 { return .overflowLow }
    }
    return .bracket(bracket)
  }

  /// Binary-searches `bracket` for the monthly rate that reproduces
  /// `target`. Returns the converged rate, or `nil` if the search never
  /// met the tolerance.
  private static func binarySearchReturnRate(
    target: Double,
    initial: RateBracket,
    futureValue: (Double) -> Double
  ) -> Double? {
    var bracket = initial
    for _ in 0..<100 {
      let guess = (bracket.high + bracket.low) / 2
      let value = futureValue(guess)
      if bracket.low > bracket.high { return guess }
      if abs(value - target) < 0.01 { return guess }
      if value > target {
        bracket.high = guess - 0.0001
      } else {
        bracket.low = guess + 0.0001
      }
    }
    return nil
  }

  func costBasisSnapshot(
    transactions: [Transaction], hostCurrency: Instrument
  ) async -> [String: Decimal] {
    var engine = CostBasisEngine()
    // Track instruments whose cost basis has been corrupted by a failing
    // classification (e.g., a historical exchange rate gap on a swap). Per
    // Rule 11 we must NOT return a silently-wrong number for these — omit
    // them from the result so the caller treats the cost basis as
    // unavailable rather than wrong.
    var instrumentsWithFailedClassification: Set<String> = []
    let sorted = transactions.sorted { $0.date < $1.date }
    for txn in sorted {
      guard !Task.isCancelled else { break }
      do {
        let classification = try await TradeEventClassifier.classify(
          legs: txn.legs, on: txn.date,
          hostCurrency: hostCurrency, conversionService: conversionService
        )
        for buy in classification.buys {
          engine.processBuy(
            instrument: buy.instrument, quantity: buy.quantity,
            costPerUnit: buy.costPerUnit, date: txn.date)
        }
        for sell in classification.sells {
          _ = engine.processSell(
            instrument: sell.instrument, quantity: sell.quantity,
            proceedsPerUnit: sell.proceedsPerUnit, date: txn.date)
        }
      } catch {
        logger.warning(
          "Failed to classify txn \(txn.id, privacy: .public) for cost basis: \(error.localizedDescription, privacy: .public)"
        )
        // Mark every non-fiat instrument in this txn's legs as having
        // uncertain cost basis going forward.
        for leg in txn.legs where leg.instrument.kind != .fiatCurrency {
          instrumentsWithFailedClassification.insert(leg.instrument.id)
        }
      }
    }
    var result: [String: Decimal] = [:]
    for lot in engine.allOpenLots() {
      result[lot.instrument.id, default: 0] += lot.remainingCost
    }
    // Drop any instrument whose cost basis is no longer reliable.
    for id in instrumentsWithFailedClassification {
      result.removeValue(forKey: id)
    }
    return result
  }
}
