import Foundation

final class RemoteAnalysisRepository: AnalysisRepository {
  private let client: APIClient

  init(client: APIClient) {
    self.client = client
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

    var balances = response.dailyBalances.map { $0.toDomain(isForecast: false) }
    if let scheduled = response.scheduledBalances {
      balances.append(contentsOf: scheduled.map { $0.toDomain(isForecast: true) })
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

    return response.map { $0.toDomain() }
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

    return response.incomeAndExpense.map { $0.toDomain() }
  }
}
