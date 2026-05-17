// MoolahTests/Backends/GRDB/ProfileSchemaTransferDetectionTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("ProfileSchema v12 transfer detection")
struct ProfileSchemaTransferDetectionTests {
  @Test("adds transfer-detection columns and dismissed_transfer_pair")
  func migrates() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    try queue.read { database in
      let txColumns = try Set(database.columns(in: "transaction").map(\.name))
      for column in [
        "transfer_suggestion_counterpart_id", "transfer_suggestion_suggested_at",
        "import_origin_kind",
        "import_origin_incoming_raw_description", "import_origin_incoming_bank_reference",
        "import_origin_incoming_raw_amount", "import_origin_incoming_raw_balance",
        "import_origin_incoming_imported_at", "import_origin_incoming_import_session_id",
        "import_origin_incoming_source_filename", "import_origin_incoming_parser_identifier",
      ] { #expect(txColumns.contains(column)) }
      #expect(try database.tableExists("dismissed_transfer_pair"))
      let dismissed = try Set(database.columns(in: "dismissed_transfer_pair").map(\.name))
      #expect(
        dismissed
          == Set([
            "id", "record_name", "transaction_id_a", "transaction_id_b",
            "dismissed_at", "encoded_system_fields",
          ]))
    }
  }
}
