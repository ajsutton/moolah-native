import Foundation
import SwiftData
import os

final class CloudKitTransactionRepository: TransactionRepository, @unchecked Sendable {
  private let modelContainer: ModelContainer
  private let instrument: Instrument
  var onRecordChanged: (UUID) -> Void = { _ in }
  var onRecordDeleted: (UUID) -> Void = { _ in }

  init(modelContainer: ModelContainer, instrument: Instrument) {
    self.modelContainer = modelContainer
    self.instrument = instrument
  }

  @MainActor
  private var context: ModelContext {
    modelContainer.mainContext
  }

  // MARK: - Instrument Cache

  @MainActor private var instrumentCache: [String: Instrument] = [:]

  @MainActor
  private func resolveInstrument(id: String) throws -> Instrument {
    if let cached = instrumentCache[id] { return cached }
    let iid = id
    let descriptor = FetchDescriptor<InstrumentRecord>(predicate: #Predicate { $0.id == iid })
    if let record = try context.fetch(descriptor).first {
      let instrument = record.toDomain()
      instrumentCache[id] = instrument
      return instrument
    }
    let instrument = Instrument.fiat(code: id)
    instrumentCache[id] = instrument
    return instrument
  }

  @MainActor
  private func ensureInstrument(_ instrument: Instrument) throws {
    let iid = instrument.id
    let descriptor = FetchDescriptor<InstrumentRecord>(predicate: #Predicate { $0.id == iid })
    if try context.fetch(descriptor).isEmpty {
      context.insert(InstrumentRecord.from(instrument))
    }
    instrumentCache[instrument.id] = instrument
  }

  // MARK: - Fetch Legs for Transactions

  @MainActor
  private func fetchLegs(for transactionId: UUID) throws -> [TransactionLeg] {
    let tid = transactionId
    let descriptor = FetchDescriptor<TransactionLegRecord>(
      predicate: #Predicate { $0.transactionId == tid },
      sortBy: [SortDescriptor(\.sortOrder)]
    )
    let legRecords = try context.fetch(descriptor)
    return try legRecords.map { record in
      let instrument = try resolveInstrument(id: record.instrumentId)
      return record.toDomain(instrument: instrument)
    }
  }

  @MainActor
  private func fetchAllLegRecords() throws -> [TransactionLegRecord] {
    let descriptor = FetchDescriptor<TransactionLegRecord>()
    return try context.fetch(descriptor)
  }

  // MARK: - Fetch

  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "TransactionRepo.fetch", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "TransactionRepo.fetch", signpostID: signpostID)
    }
    return try await MainActor.run {
      // Match moolah-server: when scheduled is not explicitly requested, exclude scheduled
      // transactions. The server always adds `AND recur_period IS NULL` unless scheduled=true.
      let scheduled = filter.scheduled ?? false

      // --- Step 1: If filtering by accountId, get matching transactionIds from legs ---
      os_signpost(
        .begin, log: Signposts.repository, name: "fetch.predicateQuery", signpostID: signpostID)
      let accountTransactionIds: Set<UUID>?
      if let filterAccountId = filter.accountId {
        let aid = filterAccountId
        let legDescriptor = FetchDescriptor<TransactionLegRecord>(
          predicate: #Predicate { $0.accountId == aid }
        )
        let matchingLegs = try context.fetch(legDescriptor)
        accountTransactionIds = Set(matchingLegs.map(\.transactionId))
      } else {
        accountTransactionIds = nil
      }

      // --- Step 2: Fetch TransactionRecords with date/scheduled predicates ---
      let allRecords = try fetchTransactionRecords(
        scheduled: scheduled,
        dateRange: filter.dateRange
      )

      // --- Step 3: Intersect with accountId filter if needed ---
      var filteredRecords: [TransactionRecord]
      if let accountIds = accountTransactionIds {
        filteredRecords = allRecords.filter { accountIds.contains($0.id) }
      } else {
        filteredRecords = allRecords
      }
      os_signpost(
        .end, log: Signposts.repository, name: "fetch.predicateQuery", signpostID: signpostID)

      // --- In-memory post-filters ---
      // scheduled and dateRange are pushed down, but re-apply as safety net
      os_signpost(
        .begin, log: Signposts.repository, name: "fetch.postFilter", signpostID: signpostID)
      if scheduled {
        filteredRecords = filteredRecords.filter { $0.recurPeriod != nil }
      } else {
        filteredRecords = filteredRecords.filter { $0.recurPeriod == nil }
      }
      if let dateRange = filter.dateRange {
        let start = dateRange.lowerBound
        let end = dateRange.upperBound
        filteredRecords = filteredRecords.filter { $0.date >= start && $0.date <= end }
      }

      // earmarkId filter: need to check legs
      if let earmarkId = filter.earmarkId {
        let eid = earmarkId
        let earmarkLegDescriptor = FetchDescriptor<TransactionLegRecord>(
          predicate: #Predicate { $0.earmarkId == eid }
        )
        let earmarkLegTxnIds = Set(try context.fetch(earmarkLegDescriptor).map(\.transactionId))
        filteredRecords = filteredRecords.filter { earmarkLegTxnIds.contains($0.id) }
      }

      // categoryIds filter: need to check legs
      if let categoryIds = filter.categoryIds, !categoryIds.isEmpty {
        // Fetch all leg records and find transactions with matching categories
        let allLegs = try fetchAllLegRecords()
        let legsByTxnId = Dictionary(grouping: allLegs, by: \.transactionId)
        filteredRecords = filteredRecords.filter { record in
          guard let legs = legsByTxnId[record.id] else { return false }
          return legs.contains { leg in
            guard let catId = leg.categoryId else { return false }
            return categoryIds.contains(catId)
          }
        }
      }

      if let payee = filter.payee, !payee.isEmpty {
        let lowered = payee.lowercased()
        filteredRecords = filteredRecords.filter { record in
          guard let recordPayee = record.payee else { return false }
          return recordPayee.lowercased().contains(lowered)
        }
      }
      os_signpost(.end, log: Signposts.repository, name: "fetch.postFilter", signpostID: signpostID)

      // --- Sort by date DESC, then id for stable ordering (matches server) ---
      os_signpost(.begin, log: Signposts.repository, name: "fetch.sort", signpostID: signpostID)
      filteredRecords.sort { a, b in
        if a.date != b.date { return a.date > b.date }
        return a.id.uuidString < b.id.uuidString
      }
      os_signpost(.end, log: Signposts.repository, name: "fetch.sort", signpostID: signpostID)

      // --- Paginate ---
      let offset = page * pageSize
      guard offset < filteredRecords.count else {
        return TransactionPage(
          transactions: [],
          priorBalance: InstrumentAmount.zero(instrument: self.instrument),
          totalCount: filteredRecords.count)
      }
      let totalCount = filteredRecords.count
      let end = min(offset + pageSize, totalCount)
      let pageRecords = filteredRecords[offset..<end]

      // Convert only the page slice to domain objects (avoid toDomain() on entire dataset)
      os_signpost(.begin, log: Signposts.repository, name: "fetch.toDomain", signpostID: signpostID)
      let pageTransactions = try pageRecords.map { record in
        let legs = try fetchLegs(for: record.id)
        return record.toDomain(legs: legs)
      }
      os_signpost(.end, log: Signposts.repository, name: "fetch.toDomain", signpostID: signpostID)

      // priorBalance = sum of leg quantities for the filtered account for records after the page
      os_signpost(
        .begin, log: Signposts.balance, name: "fetch.priorBalance", signpostID: signpostID)
      let priorBalance: InstrumentAmount
      if let filterAccountId = filter.accountId {
        let afterPageRecordIds = Set(filteredRecords[end...].map(\.id))
        let aid = filterAccountId
        let legDescriptor = FetchDescriptor<TransactionLegRecord>(
          predicate: #Predicate { $0.accountId == aid }
        )
        let allAccountLegs = try context.fetch(legDescriptor)
        var totalStorageValue: Int64 = 0
        for leg in allAccountLegs where afterPageRecordIds.contains(leg.transactionId) {
          totalStorageValue += leg.quantity
        }
        priorBalance = InstrumentAmount(
          storageValue: totalStorageValue, instrument: self.instrument)
      } else {
        priorBalance = InstrumentAmount.zero(instrument: self.instrument)
      }
      os_signpost(.end, log: Signposts.balance, name: "fetch.priorBalance", signpostID: signpostID)

      return TransactionPage(
        transactions: pageTransactions, priorBalance: priorBalance, totalCount: totalCount)
    }
  }

  // MARK: - Predicate Push-Down Helpers

  /// Fetches TransactionRecords with scheduled and dateRange filters pushed into SwiftData predicates.
  @MainActor
  private func fetchTransactionRecords(
    scheduled: Bool,
    dateRange: ClosedRange<Date>?
  ) throws -> [TransactionRecord] {
    let sortDescriptors = [SortDescriptor(\TransactionRecord.date, order: .reverse)]

    switch (scheduled, dateRange) {
    case (false, nil):
      return try context.fetch(
        FetchDescriptor<TransactionRecord>(
          predicate: #Predicate { $0.recurPeriod == nil },
          sortBy: sortDescriptors
        ))

    case (true, nil):
      return try context.fetch(
        FetchDescriptor<TransactionRecord>(
          predicate: #Predicate { $0.recurPeriod != nil },
          sortBy: sortDescriptors
        ))

    case (false, .some(let range)):
      let start = range.lowerBound
      let end = range.upperBound
      return try context.fetch(
        FetchDescriptor<TransactionRecord>(
          predicate: #Predicate {
            $0.recurPeriod == nil && $0.date >= start && $0.date <= end
          },
          sortBy: sortDescriptors
        ))

    case (true, .some(let range)):
      let start = range.lowerBound
      let end = range.upperBound
      return try context.fetch(
        FetchDescriptor<TransactionRecord>(
          predicate: #Predicate {
            $0.recurPeriod != nil && $0.date >= start && $0.date <= end
          },
          sortBy: sortDescriptors
        ))
    }
  }

  func create(_ transaction: Transaction) async throws -> Transaction {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "TransactionRepo.create", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "TransactionRepo.create", signpostID: signpostID)
    }
    let record = TransactionRecord.from(transaction)
    try await MainActor.run {
      context.insert(record)

      // Insert leg records and ensure instruments exist
      for (index, leg) in transaction.legs.enumerated() {
        try ensureInstrument(leg.instrument)
        let legRecord = TransactionLegRecord.from(
          leg, transactionId: transaction.id, sortOrder: index)
        context.insert(legRecord)
      }

      try context.save()
      onRecordChanged(transaction.id)
    }
    return transaction
  }

  func update(_ transaction: Transaction) async throws -> Transaction {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "TransactionRepo.update", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "TransactionRepo.update", signpostID: signpostID)
    }
    let txnId = transaction.id
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.id == txnId }
    )

    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.serverError(404)
      }

      // Update transaction metadata
      record.date = transaction.date
      record.payee = transaction.payee
      record.notes = transaction.notes
      record.recurPeriod = transaction.recurPeriod?.rawValue
      record.recurEvery = transaction.recurEvery

      // Delete old leg records
      let legDescriptor = FetchDescriptor<TransactionLegRecord>(
        predicate: #Predicate { $0.transactionId == txnId }
      )
      let oldLegs = try context.fetch(legDescriptor)
      for oldLeg in oldLegs {
        context.delete(oldLeg)
      }

      // Insert new leg records
      for (index, leg) in transaction.legs.enumerated() {
        try ensureInstrument(leg.instrument)
        let legRecord = TransactionLegRecord.from(
          leg, transactionId: transaction.id, sortOrder: index)
        context.insert(legRecord)
      }

      try context.save()
      onRecordChanged(transaction.id)
    }
    return transaction
  }

  func delete(id: UUID) async throws {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "TransactionRepo.delete", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "TransactionRepo.delete", signpostID: signpostID)
    }
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.id == id }
    )

    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.serverError(404)
      }

      // Delete leg records first
      let legDescriptor = FetchDescriptor<TransactionLegRecord>(
        predicate: #Predicate { $0.transactionId == id }
      )
      let legs = try context.fetch(legDescriptor)
      for leg in legs {
        context.delete(leg)
      }

      context.delete(record)
      try context.save()
      onRecordDeleted(id)
    }
  }

  func fetchPayeeSuggestions(prefix: String) async throws -> [String] {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "TransactionRepo.fetchPayeeSuggestions",
      signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "TransactionRepo.fetchPayeeSuggestions",
        signpostID: signpostID)
    }
    guard !prefix.isEmpty else { return [] }
    let descriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.payee != nil }
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
