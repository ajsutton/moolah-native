// MoolahTests/Backends/GRDB/CSVImportRollbackTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Rollback contract tests for the multi-statement writes added by
/// `v2_csv_import_and_rules`. Each method opens a transaction that
/// touches more than one row; if any statement fails, prior state must
/// survive byte-equal. Mirrors the BEFORE-INSERT-trigger pattern used
/// in `MoolahTests/Shared/ExchangeRateServicePersistenceTests.swift`
/// and `StockPriceServiceTests.swift` so the production code path is
/// exercised end-to-end (not a hand-rolled mirror).
@Suite("CSV import + import rule GRDB rollback contracts")
struct CSVImportRollbackTests {

  // MARK: - GRDBCSVImportProfileRepository.applyRemoteChangesSync

  @Test
  func csvImportProfileApplyRemoteChangesRollsBackOnFailure() async throws {
    let database = try ProfileDatabase.openInMemory()
    let repo = GRDBCSVImportProfileRepository(database: database)
    let priorId = UUID()
    let prior = makeProfileRow(
      id: priorId, parserIdentifier: "prior-bank")
    try await database.write { database in
      try prior.insert(database)
    }

    // Trigger that aborts the second insert when the parser identifier
    // matches the sentinel. The first row in the batch upserts
    // successfully; the trigger fires inside `applyRemoteChangesSync`'s
    // single transaction so all statements (including the upsert that
    // already touched the prior row) must roll back.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_csv_import_profile_upsert
          BEFORE INSERT ON csv_import_profile
          WHEN NEW.parser_identifier = '___FAIL___'
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    let mutating = makeProfileRow(
      id: priorId, parserIdentifier: "mutated-prior")
    let failing = makeProfileRow(id: UUID(), parserIdentifier: "___FAIL___")
    do {
      try repo.applyRemoteChangesSync(saved: [mutating, failing], deleted: [])
      Issue.record("applyRemoteChangesSync should have thrown but did not")
    } catch {
      // Expected — trigger raises ABORT.
    }

    let surviving = try await database.read { database in
      try CSVImportProfileRow
        .filter(CSVImportProfileRow.Columns.id == priorId)
        .fetchOne(database)
    }
    let row = try #require(surviving)
    // The mutated values from the failed batch must NOT have landed —
    // the prior row's parser identifier survives byte-equal.
    #expect(row.parserIdentifier == "prior-bank")
  }

  // MARK: - GRDBImportRuleRepository.applyRemoteChangesSync

  @Test
  func importRuleApplyRemoteChangesRollsBackOnFailure() async throws {
    let database = try ProfileDatabase.openInMemory()
    let repo = GRDBImportRuleRepository(database: database)
    let priorId = UUID()
    let prior = makeRuleRow(id: priorId, name: "prior-rule", position: 0)
    try await database.write { database in
      try prior.insert(database)
    }

    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_import_rule_upsert
          BEFORE INSERT ON import_rule
          WHEN NEW.name = '___FAIL___'
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    let mutating = makeRuleRow(id: priorId, name: "mutated-prior", position: 0)
    let failing = makeRuleRow(id: UUID(), name: "___FAIL___", position: 1)
    do {
      try repo.applyRemoteChangesSync(saved: [mutating, failing], deleted: [])
      Issue.record("applyRemoteChangesSync should have thrown but did not")
    } catch {
      // Expected.
    }

    let surviving = try await database.read { database in
      try ImportRuleRow
        .filter(ImportRuleRow.Columns.id == priorId)
        .fetchOne(database)
    }
    let row = try #require(surviving)
    #expect(row.name == "prior-rule")
  }

  // MARK: - GRDBImportRuleRepository.reorder

  @Test
  func importRuleReorderRollsBackOnFailure() async throws {
    let database = try ProfileDatabase.openInMemory()
    let repo = GRDBImportRuleRepository(database: database)
    let firstId = UUID()
    let secondId = UUID()
    // The second row carries a sentinel name; the trigger below aborts
    // any UPDATE that would touch a row with this name. `reorder`
    // iterates `ImportRuleRow.fetchAll`, so the first row's UPDATE
    // succeeds inside its single `database.write` transaction and the
    // second row's UPDATE trips the trigger — the entire transaction
    // must roll back, leaving both rows at their original positions.
    let first = makeRuleRow(id: firstId, name: "first", position: 0)
    let second = makeRuleRow(id: secondId, name: "___FAIL___", position: 1)
    try await database.write { database in
      try first.insert(database)
      try second.insert(database)
      try database.execute(
        sql: """
          CREATE TRIGGER fail_import_rule_reorder
          BEFORE UPDATE ON import_rule
          WHEN NEW.name = '___FAIL___'
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    // Drive the production `reorder` method through the constraint
    // failure: the swap moves both rows, so the second-row update will
    // hit the BEFORE-UPDATE trigger.
    do {
      try await repo.reorder([secondId, firstId])
      Issue.record("repo.reorder should have thrown but did not")
    } catch {
      // Expected — trigger raises ABORT inside reorder's transaction.
    }

    // Drop the trigger so the post-condition writes succeed.
    try await database.write { database in
      try database.execute(sql: "DROP TRIGGER fail_import_rule_reorder")
    }

    let surviving = try await database.read { database in
      try ImportRuleRow.fetchAll(database).sorted { $0.position < $1.position }
    }
    // Both rows survived at their original positions — the rolled-back
    // first UPDATE did NOT leave `first.position == 1` on disk.
    #expect(surviving.count == 2)
    let firstRow = try #require(surviving.first { $0.id == firstId })
    let secondRow = try #require(surviving.first { $0.id == secondId })
    #expect(firstRow.position == 0)
    #expect(secondRow.position == 1)

    // Rename the sentinel row and drive a happy-path `reorder` to
    // confirm the production API still works after the rollback drill
    // (i.e. nothing about the rolled-back transaction left the DB
    // inconsistent).
    var renamed = secondRow
    renamed.name = "second"
    let renamedRule = renamed.toDomain()
    _ = try await repo.update(renamedRule)
    try await repo.reorder([secondId, firstId])
    let reordered = try await database.read { database in
      try ImportRuleRow.fetchAll(database).sorted { $0.position < $1.position }
    }
    #expect(reordered.map(\.id) == [secondId, firstId])
  }

  // MARK: - Helpers

  private func makeProfileRow(
    id: UUID, parserIdentifier: String
  ) -> CSVImportProfileRow {
    CSVImportProfileRow(
      id: id,
      recordName: CSVImportProfileRow.recordName(for: id),
      accountId: UUID(),
      parserIdentifier: parserIdentifier,
      headerSignature: "date\u{1F}amount",
      filenamePattern: nil,
      deleteAfterImport: false,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      lastUsedAt: nil,
      dateFormatRawValue: nil,
      columnRoleRawValuesEncoded: nil,
      encodedSystemFields: nil)
  }

  private func makeRuleRow(id: UUID, name: String, position: Int) -> ImportRuleRow {
    ImportRuleRow(
      id: id,
      recordName: ImportRuleRow.recordName(for: id),
      name: name,
      enabled: true,
      position: position,
      matchMode: MatchMode.all.rawValue,
      conditionsJSON: Data("[]".utf8),
      actionsJSON: Data("[]".utf8),
      accountScope: nil,
      encodedSystemFields: nil)
  }
}
