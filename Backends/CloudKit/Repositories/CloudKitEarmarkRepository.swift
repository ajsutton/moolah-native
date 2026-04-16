import Foundation
import SwiftData
import os

final class CloudKitEarmarkRepository: EarmarkRepository, @unchecked Sendable {
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

  func fetchAll() async throws -> [Earmark] {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "EarmarkRepo.fetchAll", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "EarmarkRepo.fetchAll", signpostID: signpostID)
    }
    let descriptor = FetchDescriptor<EarmarkRecord>()
    return try await MainActor.run {
      let instruments = try fetchInstrumentMap()
      let records = try context.fetch(descriptor)
      return try records.map { record in
        let totals = try computeEarmarkPositions(for: record.id, instruments: instruments)
        return record.toDomain(
          defaultInstrument: instrument,
          positions: totals.positions, savedPositions: totals.savedPositions,
          spentPositions: totals.spentPositions
        )
      }.sorted()
    }
  }

  func create(_ earmark: Earmark) async throws -> Earmark {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "EarmarkRepo.create", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "EarmarkRepo.create", signpostID: signpostID)
    }
    let record = EarmarkRecord.from(earmark)
    try await MainActor.run {
      context.insert(record)
      try context.save()
      onRecordChanged(earmark.id)
    }
    return earmark
  }

  func update(_ earmark: Earmark) async throws -> Earmark {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "EarmarkRepo.update", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "EarmarkRepo.update", signpostID: signpostID)
    }
    let earmarkId = earmark.id
    let descriptor = FetchDescriptor<EarmarkRecord>(
      predicate: #Predicate { $0.id == earmarkId }
    )

    try await MainActor.run {
      guard let record = try context.fetch(descriptor).first else {
        throw BackendError.serverError(404)
      }
      record.name = earmark.name
      record.position = earmark.position
      record.isHidden = earmark.isHidden
      record.savingsTarget = earmark.savingsGoal?.storageValue
      record.savingsTargetInstrumentId = earmark.savingsGoal?.instrument.id
      record.savingsStartDate = earmark.savingsStartDate
      record.savingsEndDate = earmark.savingsEndDate
      try context.save()
      onRecordChanged(earmark.id)
    }
    return earmark
  }

  func fetchBudget(earmarkId: UUID) async throws -> [EarmarkBudgetItem] {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "EarmarkRepo.fetchBudget", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "EarmarkRepo.fetchBudget", signpostID: signpostID)
    }
    let descriptor = FetchDescriptor<EarmarkBudgetItemRecord>(
      predicate: #Predicate { $0.earmarkId == earmarkId }
    )
    return try await MainActor.run {
      let records = try context.fetch(descriptor)
      return records.map { $0.toDomain() }
    }
  }

  func setBudget(earmarkId: UUID, categoryId: UUID, amount: InstrumentAmount) async throws {
    let signpostID = OSSignpostID(log: Signposts.repository)
    os_signpost(
      .begin, log: Signposts.repository, name: "EarmarkRepo.setBudget", signpostID: signpostID)
    defer {
      os_signpost(
        .end, log: Signposts.repository, name: "EarmarkRepo.setBudget", signpostID: signpostID)
    }
    let earmarkDescriptor = FetchDescriptor<EarmarkRecord>(
      predicate: #Predicate { $0.id == earmarkId }
    )

    try await MainActor.run {
      guard try context.fetch(earmarkDescriptor).first != nil else {
        throw BackendError.serverError(404)
      }

      let budgetDescriptor = FetchDescriptor<EarmarkBudgetItemRecord>(
        predicate: #Predicate {
          $0.earmarkId == earmarkId && $0.categoryId == categoryId
        }
      )
      let existing = try context.fetch(budgetDescriptor).first

      if amount.isZero {
        if let existing {
          let deletedId = existing.id
          context.delete(existing)
          try context.save()
          onRecordDeleted(deletedId)
        }
      } else if let existing {
        existing.amount = amount.storageValue
        existing.instrumentId = amount.instrument.id
        try context.save()
        onRecordChanged(existing.id)
      } else {
        let record = EarmarkBudgetItemRecord(
          earmarkId: earmarkId,
          categoryId: categoryId,
          amount: amount.storageValue,
          instrumentId: amount.instrument.id
        )
        context.insert(record)
        try context.save()
        onRecordChanged(record.id)
      }
    }
  }

  @MainActor
  private func computeEarmarkPositions(
    for earmarkId: UUID,
    instruments: [String: Instrument]
  ) throws -> (
    positions: [Position], savedPositions: [Position], spentPositions: [Position]
  ) {
    // Get scheduled transaction IDs to exclude
    let scheduledDescriptor = FetchDescriptor<TransactionRecord>(
      predicate: #Predicate { $0.recurPeriod != nil }
    )
    let scheduledIds = Set(try context.fetch(scheduledDescriptor).map(\.id))

    // Fetch legs with this earmarkId
    let eid = earmarkId
    let descriptor = FetchDescriptor<TransactionLegRecord>(
      predicate: #Predicate { $0.earmarkId == eid }
    )
    let legRecords = try context.fetch(descriptor)

    var positionTotals: [Instrument: Decimal] = [:]
    var savedTotals: [Instrument: Decimal] = [:]
    var spentTotals: [Instrument: Decimal] = [:]

    for leg in legRecords {
      guard !scheduledIds.contains(leg.transactionId) else { continue }
      let inst = instruments[leg.instrumentId] ?? Instrument.fiat(code: leg.instrumentId)
      let amount = InstrumentAmount(storageValue: leg.quantity, instrument: inst)

      // Multi-instrument positions
      positionTotals[inst, default: 0] += amount.quantity

      // Type-based saved/spent classification
      let legType = TransactionType(rawValue: leg.type) ?? .expense
      switch legType {
      case .income, .openingBalance:
        savedTotals[inst, default: 0] += amount.quantity
      case .expense, .transfer:
        spentTotals[inst, default: 0] += -amount.quantity
      }
    }

    let positions = positionTotals.compactMap { inst, qty -> Position? in
      guard qty != 0 else { return nil }
      return Position(instrument: inst, quantity: qty)
    }.sorted { $0.instrument.id < $1.instrument.id }

    let savedPositions = savedTotals.compactMap { inst, qty -> Position? in
      guard qty != 0 else { return nil }
      return Position(instrument: inst, quantity: qty)
    }.sorted { $0.instrument.id < $1.instrument.id }

    let spentPositions = spentTotals.compactMap { inst, qty -> Position? in
      guard qty != 0 else { return nil }
      return Position(instrument: inst, quantity: qty)
    }.sorted { $0.instrument.id < $1.instrument.id }

    return (positions, savedPositions, spentPositions)
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
}
