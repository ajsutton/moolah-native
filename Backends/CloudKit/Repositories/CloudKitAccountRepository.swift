import Foundation
import OSLog
import SwiftData
import os

final class CloudKitAccountRepository: AccountRepository, @unchecked Sendable {
  private let logger = Logger(subsystem: "com.moolah.app", category: "AccountRepository")
  private let modelContainer: ModelContainer
  var onRecordChanged: (UUID) -> Void = { _ in }
  var onRecordDeleted: (UUID) -> Void = { _ in }
  var onInstrumentChanged: (String) -> Void = { _ in }

  init(modelContainer: ModelContainer) {
    self.modelContainer = modelContainer
  }

  @MainActor
  private var context: ModelContext {
    modelContainer.mainContext
  }

  func fetchAll() async throws -> [Account] {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "AccountRepo.fetchAll", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "AccountRepo.fetchAll", signpostID: signpostID)
    }
    let descriptor = FetchDescriptor<AccountRecord>(
      sortBy: [SortDescriptor(\.position)]
    )
    // Use a background context for read-only fetches to avoid blocking the main thread.
    let bgContext = ModelContext(modelContainer)
    let fetchStart = ContinuousClock.now
    let records = try bgContext.fetch(descriptor)
    let fetchMs = (ContinuousClock.now - fetchStart).inMilliseconds

    let positionStart = ContinuousClock.now
    let (_, allLegs) = try fetchNonScheduledLegs(context: bgContext)
    let instruments = try fetchInstrumentMap(context: bgContext)
    let allPositions = computePositions(from: allLegs, instruments: instruments)
    let positionMs = (ContinuousClock.now - positionStart).inMilliseconds

    let result = records.map { record in
      let positions = allPositions[record.id] ?? []
      return record.toDomain(
        instruments: instruments,
        positions: positions)
    }
    let totalMs = fetchMs + positionMs
    if totalMs > 100 {
      logger.info(
        "AccountRepo.fetchAll took \(totalMs)ms off-main (records: \(fetchMs)ms, positions: \(positionMs)ms, \(records.count) accounts)"
      )
    }
    return result
  }

  func create(_ account: Account, openingBalance: InstrumentAmount? = nil) async throws -> Account {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "AccountRepo.create", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "AccountRepo.create", signpostID: signpostID)
    }
    guard !account.name.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw BackendError.validationFailed("Account name cannot be empty")
    }

    let record = AccountRecord.from(account)
    try await MainActor.run {
      context.insert(record)

      // If an opening balance is provided, create an opening balance transaction with a leg
      if let openingBalance, !openingBalance.isZero {
        let txnId = UUID()
        let txnRecord = TransactionRecord(
          id: txnId,
          date: Date()
        )
        context.insert(txnRecord)

        try ensureInstrument(account.instrument)

        let legRecord = TransactionLegRecord(
          transactionId: txnId,
          accountId: account.id,
          instrumentId: account.instrument.id,
          quantity: openingBalance.storageValue,
          type: TransactionType.openingBalance.rawValue,
          sortOrder: 0
        )
        context.insert(legRecord)
        try context.save()
        onRecordChanged(account.id)
        onRecordChanged(txnRecord.id)
        onRecordChanged(legRecord.id)
      } else {
        try context.save()
        onRecordChanged(account.id)
      }
    }

    return account
  }

  func update(_ account: Account) async throws -> Account {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "AccountRepo.update", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "AccountRepo.update", signpostID: signpostID)
    }
    let accountId = account.id
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.id == accountId }
    )

    guard !account.name.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw BackendError.validationFailed("Account name cannot be empty")
    }

    return try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.notFound("Account not found")
      }
      record.name = account.name
      record.type = account.type.rawValue
      record.instrumentId = account.instrument.id
      record.position = account.position
      record.isHidden = account.isHidden
      try context.save()
      onRecordChanged(account.id)

      let instruments = try fetchInstrumentMap()
      let allPositions = try computeAllPositions(instruments: instruments)
      let positions = allPositions[accountId] ?? []
      return record.toDomain(
        instruments: instruments,
        positions: positions)
    }
  }

  func delete(id: UUID) async throws {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "AccountRepo.delete", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "AccountRepo.delete", signpostID: signpostID)
    }
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.id == id }
    )

    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.notFound("Account not found")
      }

      let instruments = try fetchInstrumentMap()
      let allPositions = try computeAllPositions(instruments: instruments)
      let positions = allPositions[id] ?? []
      let hasNonZeroPosition = positions.contains { $0.quantity != 0 }
      guard !hasNonZeroPosition else {
        throw BackendError.validationFailed("Cannot delete account with non-zero balance")
      }

      // Soft delete
      record.isHidden = true
      try context.save()
      onRecordChanged(id)
    }
  }

  // MARK: - Position Computation

  /// Compute per-instrument positions for all accounts.
  /// Returns a dictionary of accountId -> [Position].
  @MainActor
  private func computeAllPositions(instruments: [String: Instrument]) throws -> [UUID: [Position]] {
    let (_, allLegs) = try fetchNonScheduledLegs()

    // Group by (accountId, instrumentId) and sum quantities
    var totals: [UUID: [String: Int64]] = [:]
    for leg in allLegs {
      guard let accountId = leg.accountId else { continue }
      totals[accountId, default: [:]][leg.instrumentId, default: 0] += leg.quantity
    }

    // Resolve instruments and build Position arrays
    var result: [UUID: [Position]] = [:]
    for (accountId, instrumentTotals) in totals {
      var positions: [Position] = []
      for (instrumentId, quantity) in instrumentTotals {
        guard quantity != 0 else { continue }
        let inst = instruments[instrumentId] ?? Instrument.fiat(code: instrumentId)
        let amount = InstrumentAmount(storageValue: quantity, instrument: inst)
        positions.append(
          Position(instrument: inst, quantity: amount.quantity))
      }
      positions.sort { $0.instrument.id < $1.instrument.id }
      if !positions.isEmpty {
        result[accountId] = positions
      }
    }
    return result
  }

  /// Fetches all non-scheduled legs in a single pass.
  @MainActor
  private func fetchNonScheduledLegs() throws -> (Set<UUID>, [TransactionLegRecord]) {
    let scheduledDescriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.recurPeriod != nil }
    )
    let scheduledIds = Set(try context.fetch(scheduledDescriptor).map(\.id))

    let legDescriptor = FetchDescriptor<TransactionLegRecord>()
    let allLegs = try context.fetch(legDescriptor).filter {
      !scheduledIds.contains($0.transactionId)
    }
    return (scheduledIds, allLegs)
  }

  /// Fetches all known instruments as a lookup map.
  @MainActor
  private func fetchInstrumentMap() throws -> [String: Instrument] {
    let descriptor = FetchDescriptor<InstrumentRecord>()
    let records = try context.fetch(descriptor)
    var map: [String: Instrument] = [:]
    for record in records {
      map[record.id] = record.toDomain()
    }
    return map
  }

  // MARK: - Background Context Helpers (used by fetchAll)

  /// Fetches all non-scheduled legs using the provided context.
  private func fetchNonScheduledLegs(context: ModelContext) throws -> (
    Set<UUID>, [TransactionLegRecord]
  ) {
    let scheduledDescriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.recurPeriod != nil }
    )
    let scheduledIds = Set(try context.fetch(scheduledDescriptor).map(\.id))

    let legDescriptor = FetchDescriptor<TransactionLegRecord>()
    let allLegs = try context.fetch(legDescriptor).filter {
      !scheduledIds.contains($0.transactionId)
    }
    return (scheduledIds, allLegs)
  }

  /// Compute per-instrument positions from pre-fetched legs.
  private func computePositions(
    from allLegs: [TransactionLegRecord], instruments: [String: Instrument]
  )
    -> [UUID: [Position]]
  {
    // Group by (accountId, instrumentId) and sum quantities
    var totals: [UUID: [String: Int64]] = [:]
    for leg in allLegs {
      guard let accountId = leg.accountId else { continue }
      totals[accountId, default: [:]][leg.instrumentId, default: 0] += leg.quantity
    }

    // Resolve instruments and build Position arrays
    var result: [UUID: [Position]] = [:]
    for (accountId, instrumentTotals) in totals {
      var positions: [Position] = []
      for (instrumentId, quantity) in instrumentTotals {
        guard quantity != 0 else { continue }
        let inst = instruments[instrumentId] ?? Instrument.fiat(code: instrumentId)
        let amount = InstrumentAmount(storageValue: quantity, instrument: inst)
        positions.append(
          Position(instrument: inst, quantity: amount.quantity))
      }
      positions.sort { $0.instrument.id < $1.instrument.id }
      if !positions.isEmpty {
        result[accountId] = positions
      }
    }
    return result
  }

  /// Fetches all known instruments as a lookup map using the provided context.
  private func fetchInstrumentMap(context: ModelContext) throws -> [String: Instrument] {
    let descriptor = FetchDescriptor<InstrumentRecord>()
    let records = try context.fetch(descriptor)
    var map: [String: Instrument] = [:]
    for record in records {
      map[record.id] = record.toDomain()
    }
    return map
  }

  // MARK: - Instrument Cache

  @MainActor private var instrumentCacheForAccount: [String: Instrument] = [:]

  @MainActor
  private func ensureInstrument(_ instrument: Instrument) throws {
    let iid = instrument.id
    let descriptor = FetchDescriptor<InstrumentRecord>(predicate: #Predicate { $0.id == iid })
    if try context.fetch(descriptor).isEmpty {
      context.insert(InstrumentRecord.from(instrument))
      onInstrumentChanged(instrument.id)
    }
    instrumentCacheForAccount[instrument.id] = instrument
  }
}
