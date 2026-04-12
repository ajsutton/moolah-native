import Foundation
import SwiftData
import os

final class CloudKitAccountRepository: AccountRepository, @unchecked Sendable {
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
    return try await MainActor.run {
      let records = try context.fetch(descriptor)
      let balances = try computeAllBalances()
      let allPositions = try computeAllPositions()

      return try records.map { record in
        let storageValue = balances[record.id] ?? 0
        let balance = InstrumentAmount(storageValue: storageValue, instrument: instrument)
        let investmentValue =
          record.type == AccountType.investment.rawValue
          ? try latestInvestmentValue(for: record.id)
          : nil
        let positions = allPositions[record.id] ?? []
        return record.toDomain(
          balance: balance, investmentValue: investmentValue, positions: positions)
      }
    }
  }

  func create(_ account: Account) async throws -> Account {
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

      // If account has an opening balance, create an opening balance transaction with a leg
      if !account.balance.isZero {
        let txnId = UUID()
        let txnRecord = TransactionRecord(
          id: txnId,
          date: Date()
        )
        context.insert(txnRecord)

        try ensureInstrument(account.balance.instrument)

        let legRecord = TransactionLegRecord(
          transactionId: txnId,
          accountId: account.id,
          instrumentId: account.balance.instrument.id,
          quantity: account.balance.storageValue,
          type: TransactionType.openingBalance.rawValue,
          sortOrder: 0
        )
        context.insert(legRecord)
        try context.save()
        onRecordChanged(account.id)
        onRecordChanged(txnRecord.id)
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
      record.position = account.position
      record.isHidden = account.isHidden
      try context.save()
      onRecordChanged(account.id)

      let balances = try computeAllBalances()
      let storageValue = balances[accountId] ?? 0
      let balance = InstrumentAmount(storageValue: storageValue, instrument: instrument)
      let investmentValue =
        record.type == AccountType.investment.rawValue
        ? try latestInvestmentValue(for: accountId)
        : nil
      let allPositions = try computeAllPositions()
      let positions = allPositions[accountId] ?? []
      return record.toDomain(
        balance: balance, investmentValue: investmentValue, positions: positions)
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

      let balances = try computeAllBalances()
      let storageValue = balances[id] ?? 0
      guard storageValue == 0 else {
        throw BackendError.validationFailed("Cannot delete account with non-zero balance")
      }

      // Soft delete
      record.isHidden = true
      try context.save()
      onRecordChanged(id)
    }
  }

  // MARK: - Balance Computation

  /// Compute all account balances in a single pass over leg records.
  /// Returns a dictionary of accountId -> storageValue (Int64).
  @MainActor
  private func computeAllBalances() throws -> [UUID: Int64] {
    let (_, allLegs) = try fetchNonScheduledLegs()

    var balances: [UUID: Int64] = [:]
    for leg in allLegs {
      balances[leg.accountId, default: 0] += leg.quantity
    }
    return balances
  }

  /// Compute per-instrument positions for all accounts.
  /// Returns a dictionary of accountId -> [Position].
  @MainActor
  private func computeAllPositions() throws -> [UUID: [Position]] {
    let (_, allLegs) = try fetchNonScheduledLegs()

    // Group by (accountId, instrumentId) and sum quantities
    var totals: [UUID: [String: Int64]] = [:]
    for leg in allLegs {
      totals[leg.accountId, default: [:]][leg.instrumentId, default: 0] += leg.quantity
    }

    // Resolve instruments and build Position arrays
    let instruments = try fetchInstrumentMap()
    var result: [UUID: [Position]] = [:]
    for (accountId, instrumentTotals) in totals {
      var positions: [Position] = []
      for (instrumentId, quantity) in instrumentTotals {
        guard quantity != 0 else { continue }
        let inst = instruments[instrumentId] ?? Instrument.fiat(code: instrumentId)
        let amount = InstrumentAmount(storageValue: quantity, instrument: inst)
        positions.append(
          Position(accountId: accountId, instrument: inst, quantity: amount.quantity))
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

  // MARK: - Instrument Cache

  @MainActor private var instrumentCacheForAccount: [String: Instrument] = [:]

  @MainActor
  private func ensureInstrument(_ instrument: Instrument) throws {
    let iid = instrument.id
    let descriptor = FetchDescriptor<InstrumentRecord>(predicate: #Predicate { $0.id == iid })
    if try context.fetch(descriptor).isEmpty {
      context.insert(InstrumentRecord.from(instrument))
    }
    instrumentCacheForAccount[instrument.id] = instrument
  }

  @MainActor
  private func latestInvestmentValue(for accountId: UUID) throws -> InstrumentAmount? {
    var descriptor = FetchDescriptor<InvestmentValueRecord>(
      predicate: #Predicate { $0.accountId == accountId },
      sortBy: [SortDescriptor(\.date, order: .reverse)]
    )
    descriptor.fetchLimit = 1
    let records = try context.fetch(descriptor)
    return records.first?.toDomain().value
  }
}
