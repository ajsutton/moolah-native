// Backends/GRDB/Records/DismissedTransferPairRow+Mapping.swift

import Foundation

extension DismissedTransferPairRow {
  /// The CloudKit recordType on the wire for this record. Frozen contract.
  static let recordType = "DismissedTransferPairRecord"

  /// Canonical CloudKit `recordName` for a UUID-keyed dismissed pair.
  static func recordName(for id: UUID) -> String {
    "\(recordType)|\(id.uuidString)"
  }

  init(domain: DismissedTransferPair) {
    let sorted = domain.transactionIds.sorted { $0.uuidString < $1.uuidString }
    self.id = domain.id
    self.recordName = Self.recordName(for: domain.id)
    precondition(
      sorted.count == 2,
      "DismissedTransferPair must contain exactly two transaction ids; got \(sorted.count)")
    self.transactionIdA = sorted[0]
    self.transactionIdB = sorted[1]
    self.dismissedAt = domain.dismissedAt
    self.encodedSystemFields = nil
  }

  func toDomain() -> DismissedTransferPair {
    DismissedTransferPair(
      transactionIds: [transactionIdA, transactionIdB], dismissedAt: dismissedAt)
  }
}
