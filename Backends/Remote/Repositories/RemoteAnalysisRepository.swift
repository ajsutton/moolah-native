import Foundation

final class RemoteAnalysisRepository: AnalysisRepository, Sendable {
  private let client: APIClient
  private let instrument: Instrument

  init(client: APIClient, instrument: Instrument) {
    self.client = client
    self.instrument = instrument
  }

  func fetchDailyBalances(
    after: Date?,
    forecastUntil: Date?
  ) async throws -> [DailyBalance] {
    var queryItems: [URLQueryItem] = []
    if let after = after {
      queryItems.append(URLQueryItem(name: "after", value: after.ISO8601Format()))
    }
    if let forecastUntil = forecastUntil {
      queryItems.append(URLQueryItem(name: "forecastUntil", value: forecastUntil.ISO8601Format()))
    }

    let data = try await client.get("analysis/dailyBalances/", queryItems: queryItems)
    let response = try JSONDecoder().decode(DailyBalancesResponseDTO.self, from: data)

    var balances = response.dailyBalances.map {
      $0.toDomain(instrument: instrument, isForecast: false)
    }
    balances.append(
      contentsOf: response.scheduledBalances.map {
        $0.toDomain(instrument: self.instrument, isForecast: true)
      })
    return balances.sorted { $0.date < $1.date }
  }

  func fetchExpenseBreakdown(
    monthEnd: Int,
    after: Date?
  ) async throws -> [ExpenseBreakdown] {
    var queryItems: [URLQueryItem] = [
      URLQueryItem(name: "monthEnd", value: String(monthEnd))
    ]
    if let after = after {
      queryItems.append(URLQueryItem(name: "after", value: after.ISO8601Format()))
    }

    let data = try await client.get("analysis/expenseBreakdown/", queryItems: queryItems)
    let response = try JSONDecoder().decode([ExpenseBreakdownDTO].self, from: data)

    return response.map { $0.toDomain(instrument: instrument) }
  }

  func fetchIncomeAndExpense(
    monthEnd: Int,
    after: Date?
  ) async throws -> [MonthlyIncomeExpense] {
    var queryItems: [URLQueryItem] = [
      URLQueryItem(name: "monthEnd", value: String(monthEnd))
    ]
    if let after = after {
      queryItems.append(URLQueryItem(name: "after", value: after.ISO8601Format()))
    }

    let data = try await client.get("analysis/incomeAndExpense/", queryItems: queryItems)
    let response = try JSONDecoder().decode(IncomeAndExpenseResponseDTO.self, from: data)

    return response.incomeAndExpense.map { $0.toDomain(instrument: instrument) }
  }

  func fetchCategoryBalances(
    dateRange: ClosedRange<Date>,
    transactionType: TransactionType,
    filters: TransactionFilter?,
    targetInstrument: Instrument
  ) async throws -> [UUID: InstrumentAmount] {
    // Remote is single-instrument; callers must request the profile instrument.
    // See `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 11a.
    try requireMatchesProfileInstrument(
      targetInstrument, profile: instrument, entity: "Category balances target instrument")
    var queryItems: [URLQueryItem] = [
      URLQueryItem(name: "from", value: BackendDateFormatter.string(from: dateRange.lowerBound)),
      URLQueryItem(name: "to", value: BackendDateFormatter.string(from: dateRange.upperBound)),
      URLQueryItem(name: "transactionType", value: transactionType.rawValue),
    ]

    // Add optional filters
    if let accountId = filters?.accountId {
      queryItems.append(URLQueryItem(name: "account", value: accountId.apiString))
    }
    if let earmarkId = filters?.earmarkId {
      queryItems.append(URLQueryItem(name: "earmark", value: earmarkId.apiString))
    }
    if let categoryIds = filters?.categoryIds, !categoryIds.isEmpty {
      queryItems.append(
        contentsOf: categoryIds.map {
          URLQueryItem(name: "category", value: $0.apiString)
        })
    }
    if let payee = filters?.payee {
      queryItems.append(URLQueryItem(name: "payee", value: payee))
    }

    let data = try await client.get("analysis/categoryBalances/", queryItems: queryItems)
    let response = try JSONDecoder().decode([String: Int].self, from: data)

    // Convert string keys to UUIDs and cents to InstrumentAmount
    return response.reduce(into: [:]) { result, pair in
      if let uuid = FlexibleUUID.parse(pair.key) {
        result[uuid] = InstrumentAmount(quantity: Decimal(pair.value) / 100, instrument: instrument)
      }
    }
  }
}
