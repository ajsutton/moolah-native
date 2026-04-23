import Foundation
import SwiftData

/// Leg-fetching helpers. The bulk variant replaces the per-transaction
/// loop that caused the profile-export N+1 query hang (#353).
extension CloudKitTransactionRepository {
  /// Bulk-fetches legs for the given set of transaction ids and groups them
  /// by `transactionId`, preserving `sortOrder`. One fetch replaces the
  /// per-transaction loop that caused N+1 queries (#353).
  @MainActor
  func fetchLegs(for transactionIds: [UUID]) throws -> [UUID: [TransactionLeg]] {
    guard !transactionIds.isEmpty else { return [:] }
    let idSet = Set(transactionIds)
    let descriptor = FetchDescriptor<TransactionLegRecord>(
      predicate: #Predicate { idSet.contains($0.transactionId) },
      sortBy: [SortDescriptor(\.sortOrder)]
    )
    let legRecords = try context.fetch(descriptor)

    var result: [UUID: [TransactionLeg]] = [:]
    result.reserveCapacity(transactionIds.count)
    for record in legRecords {
      let instrument = try resolveInstrument(id: record.instrumentId)
      result[record.transactionId, default: []].append(record.toDomain(instrument: instrument))
    }
    return result
  }

  /// Full table scan — callers must ensure they've already narrowed the
  /// candidate `TransactionRecord` set before calling this. Used by the
  /// `categoryIds` post-filter where predicate-pushdown isn't viable.
  @MainActor
  func fetchAllLegRecords() throws -> [TransactionLegRecord] {
    let descriptor = FetchDescriptor<TransactionLegRecord>()
    return try context.fetch(descriptor)
  }
}
