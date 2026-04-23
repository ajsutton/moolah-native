import Foundation
import SwiftData

// Position- and instrument-map helpers split out of
// `CloudKitAccountRepository` so the main class body stays under SwiftLint's
// `type_body_length` threshold. Two flavours of the same helpers exist:
// `@MainActor` variants that run on the main context, and context-parameter
// variants used by the `fetchAll` background-context path.
extension CloudKitAccountRepository {

  // MARK: - Main-Context Helpers

  /// Compute per-instrument positions for all accounts.
  /// Returns a dictionary of accountId -> [Position].
  @MainActor
  func computeAllPositions(instruments: [String: Instrument]) throws -> [UUID: [Position]] {
    let (_, allLegs) = try fetchNonScheduledLegs()
    return computePositions(from: allLegs, instruments: instruments)
  }

  /// Fetches all non-scheduled legs in a single pass.
  @MainActor
  func fetchNonScheduledLegs() throws -> (Set<UUID>, [TransactionLegRecord]) {
    try fetchNonScheduledLegs(context: context)
  }

  /// Fetches all known instruments as a lookup map.
  @MainActor
  func fetchInstrumentMap() throws -> [String: Instrument] {
    try fetchInstrumentMap(context: context)
  }

  // MARK: - Background-Context Helpers (used by fetchAll)

  /// Fetches all non-scheduled legs using the provided context.
  func fetchNonScheduledLegs(context: ModelContext) throws -> (
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
  func computePositions(
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
  func fetchInstrumentMap(context: ModelContext) throws -> [String: Instrument] {
    let descriptor = FetchDescriptor<InstrumentRecord>()
    let records = try context.fetch(descriptor)
    var map: [String: Instrument] = [:]
    for record in records {
      map[record.id] = record.toDomain()
    }
    return map
  }
}
