import Foundation
import SwiftData

final class CloudKitInvestmentRepository: InvestmentRepository, @unchecked Sendable {
  private let modelContainer: ModelContainer
  private let instrument: Instrument
  var onRecordChanged: (UUID) -> Void = { _ in }
  var onRecordDeleted: (UUID) -> Void = { _ in }

  init(modelContainer: ModelContainer, instrument: Instrument) {
    self.modelContainer = modelContainer
    self.instrument = instrument
  }

  @MainActor private var context: ModelContext {
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

  func setValue(accountId: UUID, date: Date, value: InstrumentAmount) async throws {
    let normalizedDate = Calendar.current.startOfDay(for: date)
    let descriptor = FetchDescriptor<InvestmentValueRecord>(
      predicate: #Predicate {
        $0.accountId == accountId && $0.date == normalizedDate
      }
    )

    try await MainActor.run {
      if let existing = try context.fetch(descriptor).first {
        existing.value = value.storageValue
        existing.instrumentId = value.instrument.id
        try context.save()
        onRecordChanged(existing.id)
      } else {
        let record = InvestmentValueRecord(
          accountId: accountId, date: normalizedDate,
          value: value.storageValue, instrumentId: value.instrument.id)
        context.insert(record)
        try context.save()
        onRecordChanged(record.id)
      }
    }
  }

  func removeValue(accountId: UUID, date: Date) async throws {
    let normalizedDate = Calendar.current.startOfDay(for: date)
    let descriptor = FetchDescriptor<InvestmentValueRecord>(
      predicate: #Predicate {
        $0.accountId == accountId && $0.date == normalizedDate
      }
    )

    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.notFound("Investment value not found")
      }
      let deletedId = record.id
      context.delete(record)
      try context.save()
      onRecordDeleted(deletedId)
    }
  }

  func fetchDailyBalances(accountId: UUID) async throws -> [AccountDailyBalance] {
    try await MainActor.run {
      // Get scheduled transaction IDs to exclude
      let scheduledDescriptor = FetchDescriptor<TransactionRecord>(
        predicate: #Predicate { $0.recurPeriod != nil }
      )
      let scheduledIds = Set(try context.fetch(scheduledDescriptor).map(\.id))

      // Fetch all legs for this account
      let aid = accountId
      let legDescriptor = FetchDescriptor<TransactionLegRecord>(
        predicate: #Predicate { $0.accountId == aid }
      )
      let allLegs = try context.fetch(legDescriptor)

      // Filter out scheduled transaction legs
      let legs = allLegs.filter { !scheduledIds.contains($0.transactionId) }

      // Get transaction dates for sorting
      let txnIds = Set(legs.map(\.transactionId))
      let txnDescriptor = FetchDescriptor<TransactionRecord>()
      let txnRecords = try context.fetch(txnDescriptor)
      let txnDateById: [UUID: Date] = Dictionary(
        uniqueKeysWithValues: txnRecords.filter { txnIds.contains($0.id) }.map { ($0.id, $0.date) }
      )

      // Create (date, quantity) pairs sorted by date
      let legsWithDates = legs.compactMap { leg -> (date: Date, quantity: Int64)? in
        guard let date = txnDateById[leg.transactionId] else { return nil }
        return (date: date, quantity: leg.quantity)
      }.sorted { $0.date < $1.date }

      // Compute cumulative balance per day
      var runningStorageValue: Int64 = 0
      var dailyBalances: [(date: Date, storageValue: Int64)] = []
      let calendar = Calendar.current

      for entry in legsWithDates {
        runningStorageValue += entry.quantity

        let dayKey = calendar.startOfDay(for: entry.date)
        // Upsert: if same day, overwrite with latest cumulative value
        if let lastIndex = dailyBalances.lastIndex(where: {
          $0.date.isSameDay(as: dayKey)
        }) {
          dailyBalances[lastIndex] = (date: dayKey, storageValue: runningStorageValue)
        } else {
          dailyBalances.append((date: dayKey, storageValue: runningStorageValue))
        }
      }

      return dailyBalances.map {
        AccountDailyBalance(
          date: $0.date,
          balance: InstrumentAmount(storageValue: $0.storageValue, instrument: instrument)
        )
      }
    }
  }
}
