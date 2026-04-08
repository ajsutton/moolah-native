import Foundation

/// In-memory implementation of InvestmentRepository for tests and previews.
/// Values are stored per account, keyed by date (one value per account per day).
actor InMemoryInvestmentRepository: InvestmentRepository {
  /// Storage: accountId -> [date -> InvestmentValue]
  private var storage: [UUID: [Date: InvestmentValue]]

  init(initialValues: [UUID: [InvestmentValue]] = [:]) {
    var storage: [UUID: [Date: InvestmentValue]] = [:]
    for (accountId, values) in initialValues {
      var dateMap: [Date: InvestmentValue] = [:]
      for value in values {
        dateMap[value.date] = value
      }
      storage[accountId] = dateMap
    }
    self.storage = storage
  }

  func fetchValues(accountId: UUID, page: Int, pageSize: Int) async throws -> InvestmentValuePage {
    let accountValues = storage[accountId] ?? [:]
    let sorted = accountValues.values.sorted()  // Uses Comparable (date descending)

    let offset = page * pageSize
    guard offset < sorted.count else {
      return InvestmentValuePage(values: [], hasMore: false)
    }
    let end = min(offset + pageSize, sorted.count)
    let pageValues = Array(sorted[offset..<end])
    return InvestmentValuePage(values: pageValues, hasMore: end < sorted.count)
  }

  func setValue(accountId: UUID, date: Date, value: MonetaryAmount) async throws {
    let investmentValue = InvestmentValue(date: date, value: value)
    if storage[accountId] == nil {
      storage[accountId] = [:]
    }
    storage[accountId]![date] = investmentValue
  }

  func removeValue(accountId: UUID, date: Date) async throws {
    guard storage[accountId]?.removeValue(forKey: date) != nil else {
      throw BackendError.notFound("Investment value not found")
    }
  }
}
