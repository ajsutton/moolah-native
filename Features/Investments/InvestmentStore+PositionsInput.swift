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
        title: title, hostCurrency: hostCurrency,
        positions: valuedPositions, historicalValue: nil)
    }

    let txns: [Transaction]
    do {
      txns = try await fetchAllTransactions(repository: transactionRepository)
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
      historicalValue: series
    )
  }

  func fetchAllTransactions(
    repository: TransactionRepository
  ) async throws -> [Transaction] {
    guard let accountId = loadedAccountId else { return [] }
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
      (date: $0.date, balance: Double(truncating: $0.balance.quantity as NSDecimalNumber))
    }

    guard let firstBalance = balanceValues.first, firstBalance.balance != 0 else { return 0 }

    let calculateFutureValue = { (rate: Double) -> Double in
      var prevBalance = balanceValues[0].balance
      var val = prevBalance
      var date = balanceValues[0].date

      for i in 1...balanceValues.count {
        let nextDate = i < balanceValues.count ? balanceValues[i].date : latestValue.date
        let nextBalance = i < balanceValues.count ? balanceValues[i].balance : prevBalance
        let days = Calendar.current.dateComponents([.day], from: date, to: nextDate).day ?? 0

        if days > 0 {
          let interest = val * pow(1 + rate / 12, Double(days) / 30)
          let deposits = nextBalance - prevBalance
          prevBalance = nextBalance
          val = interest + deposits
          date = nextDate
        }
      }
      return val
    }

    var low = -1.0
    var high = 1.0

    // Ensure high is above the maximum possible return
    while calculateFutureValue(high) < targetValue {
      high *= 2
      if high > 1000 { return .infinity }
    }

    // Ensure low is below the minimum possible return
    while calculateFutureValue(low) > targetValue {
      low *= 2
      if low < -1000 { return -.infinity }
    }

    // Binary search for the rate
    for _ in 0..<100 {
      let guess = (high + low) / 2
      let futureValue = calculateFutureValue(guess)

      if low > high {
        return guess * 100
      } else if abs(futureValue - targetValue) < 0.01 {
        return guess * 100
      } else if futureValue > targetValue {
        high = guess - 0.0001
      } else {
        low = guess + 0.0001
      }
    }

    return ((high + low) / 2) * 100
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
