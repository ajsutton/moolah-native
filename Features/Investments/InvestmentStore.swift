import Foundation
import OSLog
import Observation

@Observable
@MainActor
final class InvestmentStore {
  private(set) var values: [InvestmentValue] = []
  private(set) var hasMore = false
  private(set) var isLoading = false
  private(set) var error: Error?

  private var currentPage = 0
  private let pageSize = 50

  private let repository: InvestmentRepository
  private let logger = Logger(subsystem: "com.moolah.app", category: "InvestmentStore")

  init(repository: InvestmentRepository) {
    self.repository = repository
  }

  func loadValues(accountId: UUID, reset: Bool = false) async {
    if reset {
      currentPage = 0
      values = []
    }

    guard !isLoading else { return }
    isLoading = true
    error = nil

    do {
      let page = try await repository.fetchValues(
        accountId: accountId,
        page: currentPage,
        pageSize: pageSize
      )

      if reset {
        values = page.values
      } else {
        values.append(contentsOf: page.values)
      }

      hasMore = page.hasMore
      currentPage += 1
    } catch {
      logger.error("Failed to load investment values: \(error.localizedDescription)")
      self.error = error
    }

    isLoading = false
  }

  func setValue(accountId: UUID, date: Date, value: MonetaryAmount) async {
    error = nil
    do {
      try await repository.setValue(accountId: accountId, date: date, value: value)
      let newValue = InvestmentValue(date: date, value: value)
      // Remove existing value for this date if present, then insert
      values.removeAll { $0.date == date }
      values.append(newValue)
      values.sort()
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
    } catch {
      logger.error("Failed to remove investment value: \(error.localizedDescription)")
      self.error = error
    }
  }
}
