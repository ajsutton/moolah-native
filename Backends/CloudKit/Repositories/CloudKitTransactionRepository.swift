import Foundation
import SwiftData

final class CloudKitTransactionRepository: TransactionRepository, @unchecked Sendable {
  private let modelContainer: ModelContainer
  private let profileId: UUID
  private let currency: Currency

  init(modelContainer: ModelContainer, profileId: UUID, currency: Currency) {
    self.modelContainer = modelContainer
    self.profileId = profileId
    self.currency = currency
  }

  @MainActor
  private var context: ModelContext {
    modelContainer.mainContext
  }

  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage {
    let profileId = self.profileId
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.profileId == profileId }
    )

    return try await MainActor.run {
      let allRecords = try context.fetch(descriptor)
      var result = allRecords.map { $0.toDomain() }

      // Apply filters (matches InMemoryTransactionRepository exactly)
      if let accountId = filter.accountId {
        result = result.filter { $0.accountId == accountId || $0.toAccountId == accountId }
      }
      if let earmarkId = filter.earmarkId {
        result = result.filter { $0.earmarkId == earmarkId }
      }
      if let scheduled = filter.scheduled {
        result = result.filter { $0.isScheduled == scheduled }
      }
      if let dateRange = filter.dateRange {
        result = result.filter { dateRange.contains($0.date) }
      }
      if let categoryIds = filter.categoryIds, !categoryIds.isEmpty {
        result = result.filter { transaction in
          guard let categoryId = transaction.categoryId else { return false }
          return categoryIds.contains(categoryId)
        }
      }
      if let payee = filter.payee, !payee.isEmpty {
        let lowered = payee.lowercased()
        result = result.filter { transaction in
          guard let transactionPayee = transaction.payee else { return false }
          return transactionPayee.lowercased().contains(lowered)
        }
      }

      // Sort by date DESC, then id for stable ordering (matches server)
      result.sort { a, b in
        if a.date != b.date { return a.date > b.date }
        return a.id.uuidString < b.id.uuidString
      }

      // Paginate
      let offset = page * pageSize
      guard offset < result.count else {
        return TransactionPage(
          transactions: [], priorBalance: MonetaryAmount(cents: 0, currency: self.currency))
      }
      let end = min(offset + pageSize, result.count)
      let pageTransactions = Array(result[offset..<end])

      // priorBalance = sum of all transactions older than this page
      let priorBalance = result[end...].reduce(MonetaryAmount(cents: 0, currency: self.currency)) {
        $0 + $1.amount
      }

      return TransactionPage(transactions: pageTransactions, priorBalance: priorBalance)
    }
  }

  func create(_ transaction: Transaction) async throws -> Transaction {
    let record = TransactionRecord.from(transaction, profileId: profileId)
    try await MainActor.run {
      context.insert(record)
      try context.save()
    }
    return transaction
  }

  func update(_ transaction: Transaction) async throws -> Transaction {
    let txnId = transaction.id
    let profileId = self.profileId
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.id == txnId && $0.profileId == profileId }
    )

    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.serverError(404)
      }
      record.type = transaction.type.rawValue
      record.date = transaction.date
      record.accountId = transaction.accountId
      record.toAccountId = transaction.toAccountId
      record.amount = transaction.amount.cents
      record.currencyCode = transaction.amount.currency.code
      record.payee = transaction.payee
      record.notes = transaction.notes
      record.categoryId = transaction.categoryId
      record.earmarkId = transaction.earmarkId
      record.recurPeriod = transaction.recurPeriod?.rawValue
      record.recurEvery = transaction.recurEvery
      try context.save()
    }
    return transaction
  }

  func delete(id: UUID) async throws {
    let profileId = self.profileId
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.id == id && $0.profileId == profileId }
    )

    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.serverError(404)
      }
      context.delete(record)
      try context.save()
    }
  }

  func fetchPayeeSuggestions(prefix: String) async throws -> [String] {
    guard !prefix.isEmpty else { return [] }
    let profileId = self.profileId
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.profileId == profileId && $0.payee != nil }
    )

    return try await MainActor.run {
      let records = try context.fetch(descriptor)
      let lowered = prefix.lowercased()
      let matching = records.compactMap(\.payee)
        .filter { !$0.isEmpty && $0.lowercased().hasPrefix(lowered) }

      var counts: [String: Int] = [:]
      for payee in matching {
        counts[payee, default: 0] += 1
      }
      return counts.sorted { $0.value > $1.value }.map(\.key)
    }
  }
}
