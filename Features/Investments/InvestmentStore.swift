// swiftlint:disable multiline_arguments

import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class InvestmentStore {
  private(set) var values: [InvestmentValue] = []
  private(set) var dailyBalances: [AccountDailyBalance] = []
  private(set) var isLoading = false
  private(set) var error: Error?
  private(set) var positions: [Position] = []
  private(set) var valuedPositions: [ValuedPosition] = []
  /// Total portfolio value in the profile currency. `nil` when any
  /// individual position's conversion failed — per Rule 11 in
  /// `guides/INSTRUMENT_CONVERSION_GUIDE.md` we must not display a
  /// partial sum as the portfolio total.
  private(set) var totalPortfolioValue: Decimal?

  var selectedPeriod: TimePeriod = .all
  private(set) var loadedAccountId: UUID?
  private(set) var loadedHostCurrency: Instrument?

  /// Callback fired after an investment value is set or removed, so other stores
  /// can update the account's displayed investment value.
  /// Parameters: (accountId, latest value or nil if all values removed).
  var onInvestmentValueChanged:
    (@MainActor (_ accountId: UUID, _ latestValue: InstrumentAmount?) -> Void)?

  private let repository: InvestmentRepository
  private let transactionRepository: TransactionRepository?
  private let conversionService: any InstrumentConversionService
  private let logger = Logger(subsystem: "com.moolah.app", category: "InvestmentStore")

  init(
    repository: InvestmentRepository,
    transactionRepository: TransactionRepository? = nil,
    conversionService: any InstrumentConversionService
  ) {
    self.repository = repository
    self.transactionRepository = transactionRepository
    self.conversionService = conversionService
  }

  /// Load all values for the account.
  ///
  /// Per `guides/CONCURRENCY_GUIDE.md`, pagination loops must check
  /// `Task.isCancelled` after each network round-trip so that when the
  /// caller is cancelled (e.g. the `.task` on `InvestmentAccountView`
  /// tears down) we stop paginating immediately rather than fetching
  /// every remaining page and then discarding the result.
  func loadValues(accountId: UUID) async {
    do {
      var all: [InvestmentValue] = []
      var page = 0
      let batchSize = 200
      while true {
        let result = try await repository.fetchValues(
          accountId: accountId, page: page, pageSize: batchSize)
        guard !Task.isCancelled else { return }
        all.append(contentsOf: result.values)
        if !result.hasMore { break }
        page += 1
      }
      values = all
    } catch {
      logger.error("Failed to load investment values: \(error.localizedDescription)")
      self.error = error
    }
  }

  func loadDailyBalances(accountId: UUID) async {
    do {
      dailyBalances = try await repository.fetchDailyBalances(accountId: accountId)
    } catch {
      logger.error("Failed to load daily balances: \(error.localizedDescription)")
      self.error = error
    }
  }

  /// Load all data for an investment account at once.
  func loadAll(accountId: UUID) async {
    isLoading = true
    error = nil
    async let valuesLoad: Void = loadValues(accountId: accountId)
    async let balancesLoad: Void = loadDailyBalances(accountId: accountId)
    _ = await (valuesLoad, balancesLoad)
    isLoading = false
  }

  /// Loads the full dataset required by `InvestmentAccountView`, branching on
  /// whether the account uses legacy manual valuations or position tracking.
  /// Keeps the branching logic out of the view so `.task`/`.refreshable`
  /// blocks stay one-liners.
  func loadAllData(accountId: UUID, profileCurrency: Instrument) async {
    loadedHostCurrency = profileCurrency
    await loadValues(accountId: accountId)
    if hasLegacyValuations {
      await loadDailyBalances(accountId: accountId)
    } else {
      await loadPositions(accountId: accountId)
      await valuatePositions(profileCurrency: profileCurrency, on: Date())
    }
  }

  /// Refreshes position data after a trade is recorded. Used from
  /// `.onChange` where we only care about position-tracked accounts.
  func reloadPositionsIfNeeded(accountId: UUID, profileCurrency: Instrument) async {
    guard !hasLegacyValuations else { return }
    await loadPositions(accountId: accountId)
    await valuatePositions(profileCurrency: profileCurrency, on: Date())
  }

  func setValue(accountId: UUID, date: Date, value: InstrumentAmount) async {
    error = nil
    do {
      try await repository.setValue(accountId: accountId, date: date, value: value)
      let newValue = InvestmentValue(date: date, value: value)
      values.removeAll { $0.date.isSameDay(as: date) }
      values.append(newValue)
      values.sort()
      // The latest value is the first one (values sorted descending by date)
      onInvestmentValueChanged?(accountId, values.first?.value)
    } catch {
      logger.error("Failed to set investment value: \(error.localizedDescription)")
      self.error = error
    }
  }

  func removeValue(accountId: UUID, date: Date) async {
    error = nil
    do {
      try await repository.removeValue(accountId: accountId, date: date)
      values.removeAll { $0.date.isSameDay(as: date) }
      onInvestmentValueChanged?(accountId, values.first?.value)
    } catch {
      logger.error("Failed to remove investment value: \(error.localizedDescription)")
      self.error = error
    }
  }

  /// Whether the account has legacy manual valuations (InvestmentValueRecords).
  /// When true, the UI shows the legacy chart + valuations list.
  /// When false, the UI shows position tracking from transaction legs.
  var hasLegacyValuations: Bool { !values.isEmpty }

  // MARK: - Position Tracking

  /// Load positions for a position-tracked account by computing them from transaction legs.
  func loadPositions(accountId: UUID) async {
    guard let transactionRepository else {
      logger.warning("loadPositions called without transactionRepository")
      return
    }
    do {
      var allTransactions: [Transaction] = []
      var page = 0
      while true {
        let result = try await transactionRepository.fetch(
          filter: TransactionFilter(accountId: accountId),
          page: page,
          pageSize: 200
        )
        // Per guides/CONCURRENCY_GUIDE.md: stop paginating as soon as
        // the enclosing task is cancelled so we don't keep hitting the
        // network after the view that requested this data has gone.
        guard !Task.isCancelled else { return }
        allTransactions.append(contentsOf: result.transactions)
        if result.transactions.count < 200 { break }
        page += 1
      }

      var quantityByInstrument: [Instrument: Decimal] = [:]
      for txn in allTransactions {
        for leg in txn.legs where leg.accountId == accountId {
          quantityByInstrument[leg.instrument, default: 0] += leg.quantity
        }
      }

      loadedAccountId = accountId
      positions = quantityByInstrument.compactMap { instrument, quantity in
        guard quantity != 0 else { return nil }
        return Position(instrument: instrument, quantity: quantity)
      }.sorted { $0.instrument.name < $1.instrument.name }
    } catch {
      logger.error("Failed to load positions: \(error.localizedDescription)")
      self.error = error
    }
  }

  /// Valuate all loaded positions using current market prices.
  ///
  /// Per Rule 11 in `guides/INSTRUMENT_CONVERSION_GUIDE.md`: if any
  /// position's conversion fails, the aggregate `totalPortfolioValue`
  /// is marked unavailable (`nil`) and `error` is set so the view can
  /// surface a retry affordance. Per-position `ValuedPosition`s still
  /// render individually — the failing position appears with a `nil`
  /// `value` and sibling positions with their successful values.
  func valuatePositions(profileCurrency: Instrument, on date: Date) async {
    var valued: [ValuedPosition] = []
    var total: Decimal = 0
    var firstFailure: Error?

    for position in positions {
      if position.instrument.id == profileCurrency.id {
        valued.append(
          ValuedPosition(
            instrument: position.instrument,
            quantity: position.quantity,
            unitPrice: nil,
            costBasis: nil,
            value: InstrumentAmount(quantity: position.quantity, instrument: profileCurrency)
          ))
        total += position.quantity
        continue
      }
      do {
        let value = try await conversionService.convert(
          position.quantity, from: position.instrument, to: profileCurrency, on: date
        )
        let unit =
          position.quantity == 0
          ? nil
          : InstrumentAmount(quantity: value / position.quantity, instrument: profileCurrency)
        valued.append(
          ValuedPosition(
            instrument: position.instrument,
            quantity: position.quantity,
            unitPrice: unit,
            costBasis: nil,
            value: InstrumentAmount(quantity: value, instrument: profileCurrency)
          ))
        total += value
      } catch {
        logger.warning(
          "Failed to valuate position \(position.instrument.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        valued.append(
          ValuedPosition(
            instrument: position.instrument,
            quantity: position.quantity,
            unitPrice: nil,
            costBasis: nil,
            value: nil
          ))
        if firstFailure == nil { firstFailure = error }
      }
    }

    valuedPositions = valued
    if let firstFailure {
      totalPortfolioValue = nil
      self.error = firstFailure
    } else {
      totalPortfolioValue = total
    }
  }

  // MARK: - Computed Properties

  /// Investment values filtered by the selected time period.
  var filteredValues: [InvestmentValue] {
    guard let startDate = selectedPeriod.startDate else { return values }
    return values.filter { $0.date >= startDate }
  }

  /// Daily balances filtered by the selected time period.
  var filteredBalances: [AccountDailyBalance] {
    guard let startDate = selectedPeriod.startDate else { return dailyBalances }
    return dailyBalances.filter { $0.date >= startDate }
  }

  /// Merged chart data points combining values and balances.
  /// Follows the web app's algorithm: merge by date, forward-fill gaps, compute profit/loss.
  var chartDataPoints: [InvestmentChartDataPoint] {
    mergeChartData(
      values: values,
      balances: dailyBalances,
      period: selectedPeriod
    )
  }

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

  private func fetchAllTransactions(
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

  private func costBasisSnapshot(
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
}

// MARK: - Chart Data Merging

/// Merges investment values and daily balances into chart data points.
/// Algorithm ported from InvestmentValueGraph.vue:61-141.
func mergeChartData(
  values: [InvestmentValue],
  balances: [AccountDailyBalance],
  period: TimePeriod
) -> [InvestmentChartDataPoint] {
  let startDate = period.startDate

  // Collect all data points keyed by date
  var dataByDate: [Date: (value: Decimal?, balance: Decimal?)] = [:]

  var startValue: InvestmentValue?
  var startBalance: AccountDailyBalance?

  for value in values {
    if let startDate, value.date < startDate {
      if value.date > (startValue?.date ?? .distantPast) { startValue = value }
      continue
    }
    let existing = dataByDate[value.date]
    dataByDate[value.date] = (value: value.value.quantity, balance: existing?.balance)
  }

  for balance in balances {
    if let startDate, balance.date < startDate {
      if balance.date > (startBalance?.date ?? .distantPast) { startBalance = balance }
      continue
    }
    let existing = dataByDate[balance.date]
    dataByDate[balance.date] = (value: existing?.value, balance: balance.balance.quantity)
  }

  // If we have pre-period values, add them at the start date
  if let startDate {
    if let seedValue = startValue {
      let existing = dataByDate[startDate]
      dataByDate[startDate] = (
        value: existing?.value ?? seedValue.value.quantity,
        balance: existing?.balance
      )
    }
    if let seedBalance = startBalance {
      let existing = dataByDate[startDate]
      dataByDate[startDate] = (
        value: existing?.value,
        balance: existing?.balance ?? seedBalance.balance.quantity
      )
    }
  }

  // Sort by date and forward-fill gaps
  var sorted = dataByDate.map { (date: $0.key, value: $0.value.value, balance: $0.value.balance) }
  sorted.sort { $0.date < $1.date }

  var lastValue: Decimal?
  var lastBalance: Decimal?
  var result: [InvestmentChartDataPoint] = []

  for item in sorted {
    let currentValue = item.value ?? lastValue
    let currentBalance = item.balance ?? lastBalance

    if let itemValue = item.value { lastValue = itemValue }
    if let itemBalance = item.balance { lastBalance = itemBalance }

    let profitLoss: Decimal? =
      if let value = currentValue, let balance = currentBalance {
        value - balance
      } else {
        nil
      }

    result.append(
      InvestmentChartDataPoint(
        date: item.date,
        value: currentValue,
        balance: currentBalance,
        profitLoss: profitLoss
      ))
  }

  return result
}
