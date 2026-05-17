// Backends/GRDB/Records/DismissedTransferPairRow.swift

import Foundation
import GRDB

/// One row in the `dismissed_transfer_pair` table. The two transaction
/// ids are stored sorted (`transactionIdA` < `transactionIdB` by
/// `uuidString`) so a re-dismissal on any device upserts the same row.
struct DismissedTransferPairRow {
  static let databaseTableName = "dismissed_transfer_pair"

  enum Columns: String, ColumnExpression, CaseIterable {
    case id
    case recordName = "record_name"
    case transactionIdA = "transaction_id_a"
    case transactionIdB = "transaction_id_b"
    case dismissedAt = "dismissed_at"
    case encodedSystemFields = "encoded_system_fields"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordName = "record_name"
    case transactionIdA = "transaction_id_a"
    case transactionIdB = "transaction_id_b"
    case dismissedAt = "dismissed_at"
    case encodedSystemFields = "encoded_system_fields"
  }

  var id: UUID
  var recordName: String
  var transactionIdA: UUID
  var transactionIdB: UUID
  var dismissedAt: Date
  var encodedSystemFields: Data?
}

extension DismissedTransferPairRow: Codable {}
extension DismissedTransferPairRow: Sendable {}
extension DismissedTransferPairRow: Identifiable {}
extension DismissedTransferPairRow: FetchableRecord {}
extension DismissedTransferPairRow: PersistableRecord {}
extension DismissedTransferPairRow: GRDBSystemFieldsStampable {}
