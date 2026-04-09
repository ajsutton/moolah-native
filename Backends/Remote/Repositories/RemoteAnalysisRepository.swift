import Foundation

final class RemoteAnalysisRepository: AnalysisRepository, Sendable {
  private let client: APIClient
  private let currency: Currency

  init(client: APIClient, currency: Currency) {
    self.client = client
    self.currency = currency
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

    var balances = response.dailyBalances.map { $0.toDomain(currency: currency, isForecast: false) }
    if let scheduled = response.scheduledBalances {
      balances.append(
        contentsOf: scheduled.map { $0.toDomain(currency: self.currency, isForecast: true) })
    }
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

    return response.map { $0.toDomain(currency: currency) }
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

    return response.incomeAndExpense.map { $0.toDomain(currency: currency) }
  }

  func fetchCategoryBalances(
    dateRange: ClosedRange<Date>,
    transactionType: TransactionType,
    filters: TransactionFilter?
  ) async throws -> [UUID: MonetaryAmount] {
    var queryItems: [URLQueryItem] = [
      URLQueryItem(name: "from", value: BackendDateFormatter.string(from: dateRange.lowerBound)),
      URLQueryItem(name: "to", value: BackendDateFormatter.string(from: dateRange.upperBound)),
      URLQueryItem(name: "transactionType", value: transactionType.rawValue),
    ]

    // Add optional filters
    if let accountId = filters?.accountId {
      queryItems.append(URLQueryItem(name: "account", value: accountId.uuidString))
    }
    if let earmarkId = filters?.earmarkId {
      queryItems.append(URLQueryItem(name: "earmark", value: earmarkId.uuidString))
    }
    if let categoryIds = filters?.categoryIds {
      queryItems.append(
        contentsOf: categoryIds.map {
          URLQueryItem(name: "category", value: $0.uuidString)
        })
    }
    if let payee = filters?.payee {
      queryItems.append(URLQueryItem(name: "payee", value: payee))
    }

    let data = try await client.get("analysis/categoryBalances/", queryItems: queryItems)
    let response = try JSONDecoder().decode([String: Int].self, from: data)

    // Convert string keys to UUIDs and cents to MonetaryAmount (server doesn't specify currency)
    return response.reduce(into: [:]) { result, pair in
      if let uuid = FlexibleUUID.parse(pair.key) {
        result[uuid] = MonetaryAmount(cents: pair.value, currency: currency)
      }
    }
  }
}
