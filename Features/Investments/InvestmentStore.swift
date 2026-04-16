import Foundation
import OSLog
import Observation

/// A position with its current market value in the profile currency.
struct ValuedPosition: Identifiable, Sendable {
  let position: Position
  var marketValue: Decimal?  // nil if price lookup failed

  var id: String { position.instrument.id }
}

@Observable
@MainActor
final class InvestmentStore {
  private(set) var values: [InvestmentValue] = []
  private(set) var dailyBalances: [AccountDailyBalance] = []
  private(set) var isLoading = false
  private(set) var error: Error?
  private(set) var positions: [Position] = []
  private(set) var valuedPositions: [ValuedPosition] = []
  private(set) var totalPortfolioValue: Decimal = 0

  var selectedPeriod: TimePeriod = .all

  /// Callback fired after an investment value is set or removed, so other stores
  /// can update the account's displayed investment value.
  /// Parameters: (accountId, latest value or nil if all values removed).
  var onInvestmentValueChanged:
    (@MainActor (_ accountId: UUID, _ latestValue: InstrumentAmount?) -> Void)?

  private let repository: InvestmentRepository
  private let transactionRepository: TransactionRepository?
  private let conversionService: (any InstrumentConversionService)?
  private let logger = Logger(subsystem: "com.moolah.app", category: "InvestmentStore")

  init(
    repository: InvestmentRepository,
    transactionRepository: TransactionRepository? = nil,
    conversionService: (any InstrumentConversionService)? = nil
  ) {
    self.repository = repository
    self.transactionRepository = transactionRepository
    self.conversionService = conversionService
  }

  /// Load all values for the account.
  func loadValues(accountId: UUID) async {
    do {
      var all: [InvestmentValue] = []
      var page = 0
      let batchSize = 200
      while true {
        let result = try await repository.fetchValues(
          accountId: accountId, page: page, pageSize: batchSize)
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

  func setValue(accountId: UUID, date: Date, value: InstrumentAmount) async {
    error = nil
    do {
      try await repository.setValue(accountId: accountId, date: date, value: value)
      let newValue = InvestmentValue(date: date, value: value)
      values.removeAll { $0.date == date }
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
      values.removeAll { $0.date == date }
      onInvestmentValueChanged?(accountId, values.first?.value)
    } catch {
      logger.error("Failed to remove investment value: \(error.localizedDescription)")
      self.error = error
    }
  }

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
  func valuatePositions(profileCurrency: Instrument, on date: Date) async {
    guard let conversionService else {
      valuedPositions = positions.map { ValuedPosition(position: $0, marketValue: nil) }
      return
    }

    var valued: [ValuedPosition] = []
    var total: Decimal = 0

    for position in positions {
      if position.instrument.kind == .fiatCurrency {
        // Fiat positions: convert to profile currency if different
        let value: Decimal
        if position.instrument.id == profileCurrency.id {
          value = position.quantity
        } else {
          do {
            value = try await conversionService.convert(
              position.quantity, from: position.instrument, to: profileCurrency, on: date
            )
          } catch {
            valued.append(ValuedPosition(position: position, marketValue: nil))
            continue
          }
        }
        valued.append(ValuedPosition(position: position, marketValue: value))
        total += value
      } else {
        // Stock positions: convert quantity to profile currency value
        do {
          let value = try await conversionService.convert(
            position.quantity, from: position.instrument, to: profileCurrency, on: date
          )
          valued.append(ValuedPosition(position: position, marketValue: value))
          total += value
        } catch {
          valued.append(ValuedPosition(position: position, marketValue: nil))
        }
      }
    }

    valuedPositions = valued
    totalPortfolioValue = total
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
      let fv = calculateFutureValue(guess)

      if low > high {
        return guess * 100
      } else if abs(fv - targetValue) < 0.01 {
        return guess * 100
      } else if fv > targetValue {
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
      // Track the closest value before the start date
      if startValue == nil || value.date > startValue!.date {
        startValue = value
      }
      continue
    }
    let existing = dataByDate[value.date]
    dataByDate[value.date] = (value: value.value.quantity, balance: existing?.balance)
  }

  for balance in balances {
    if let startDate, balance.date < startDate {
      // Track the closest balance before the start date
      if startBalance == nil || balance.date > startBalance!.date {
        startBalance = balance
      }
      continue
    }
    let existing = dataByDate[balance.date]
    dataByDate[balance.date] = (value: existing?.value, balance: balance.balance.quantity)
  }

  // If we have pre-period values, add them at the start date
  if let startDate {
    if let sv = startValue {
      let existing = dataByDate[startDate]
      dataByDate[startDate] = (
        value: existing?.value ?? sv.value.quantity,
        balance: existing?.balance
      )
    }
    if let sb = startBalance {
      let existing = dataByDate[startDate]
      dataByDate[startDate] = (
        value: existing?.value,
        balance: existing?.balance ?? sb.balance.quantity
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

    if let v = item.value { lastValue = v }
    if let b = item.balance { lastBalance = b }

    let profitLoss: Decimal? =
      if let v = currentValue, let b = currentBalance {
        v - b
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
