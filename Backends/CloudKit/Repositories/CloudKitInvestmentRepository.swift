import Foundation
import SwiftData

final class CloudKitInvestmentRepository: InvestmentRepository, @unchecked Sendable {
  private let modelContainer: ModelContainer
  private let currency: Currency

  init(modelContainer: ModelContainer, currency: Currency) {
    self.modelContainer = modelContainer
    self.currency = currency
  }

  @MainActor
  private var context: ModelContext {
    modelContainer.mainContext
  }

  func fetchValues(accountId: UUID, page: Int, pageSize: Int) async throws -> InvestmentValuePage {
    var descriptor = FetchDescriptor<InvestmentValueRecord>(
      predicate: #Predicate { $0.accountId == accountId },
      sortBy: [SortDescriptor(\.date, order: .reverse)]
    )
    descriptor.fetchOffset = page * pageSize
    descriptor.fetchLimit = pageSize

    let countDescriptor = FetchDescriptor<InvestmentValueRecord>(
      predicate: #Predicate { $0.accountId == accountId }
    )

    return try await MainActor.run {
      let records = try context.fetch(descriptor)
      let totalCount = try context.fetchCount(countDescriptor)
      let pageValues = records.map { $0.toDomain() }
      let nextOffset = (page + 1) * pageSize
      return InvestmentValuePage(values: pageValues, hasMore: nextOffset < totalCount)
    }
  }

  func setValue(accountId: UUID, date: Date, value: MonetaryAmount) async throws {
    let descriptor = FetchDescriptor<InvestmentValueRecord>(
      predicate: #Predicate {
        $0.accountId == accountId && $0.date == date
      }
    )

    try await MainActor.run {
      if let existing = try context.fetch(descriptor).first {
        existing.value = value.cents
        existing.currencyCode = value.currency.code
      } else {
        let record = InvestmentValueRecord(
          accountId: accountId, date: date,
          value: value.cents, currencyCode: value.currency.code)
        context.insert(record)
      }
      try context.save()
    }
  }

  func removeValue(accountId: UUID, date: Date) async throws {
    let descriptor = FetchDescriptor<InvestmentValueRecord>(
      predicate: #Predicate {
        $0.accountId == accountId && $0.date == date
      }
    )

    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.notFound("Investment value not found")
      }
      context.delete(record)
      try context.save()
    }
  }

  func fetchDailyBalances(accountId: UUID) async throws -> [AccountDailyBalance] {
    let descriptor = FetchDescriptor<TransactionRecord>()
    return try await MainActor.run {
      let allRecords = try context.fetch(descriptor)
      // Filter to non-scheduled transactions involving this account
      let records = allRecords.filter { record in
        guard record.recurPeriod == nil else { return false }
        return record.accountId == accountId || record.toAccountId == accountId
      }

      // Sort by date ascending
      let sorted = records.sorted { $0.date < $1.date }

      // Compute cumulative balance per day
      var runningBalance = 0
      var dailyBalances: [(date: Date, balance: Int)] = []
      let calendar = Calendar.current

      for record in sorted {
        let txnType = TransactionType(rawValue: record.type) ?? .expense

        switch txnType {
        case .income, .expense, .openingBalance:
          if record.accountId == accountId {
            runningBalance += record.amount
          }
        case .transfer:
          // Amount sign is from accountId's perspective: use it directly for accountId,
          // negate for toAccountId (mirrors server's SUM(IF(to_account=?,-amount,amount)))
          if record.accountId == accountId {
            runningBalance += record.amount
          } else if record.toAccountId == accountId {
            runningBalance -= record.amount
          }
        }

        let dayKey = calendar.startOfDay(for: record.date)
        // Upsert: if same day, overwrite with latest cumulative value
        if let lastIndex = dailyBalances.lastIndex(where: {
          calendar.isDate($0.date, inSameDayAs: dayKey)
        }) {
          dailyBalances[lastIndex] = (date: dayKey, balance: runningBalance)
        } else {
          dailyBalances.append((date: dayKey, balance: runningBalance))
        }
      }

      return dailyBalances.map {
        AccountDailyBalance(
          date: $0.date,
          balance: MonetaryAmount(cents: $0.balance, currency: currency)
        )
      }
    }
  }
}
