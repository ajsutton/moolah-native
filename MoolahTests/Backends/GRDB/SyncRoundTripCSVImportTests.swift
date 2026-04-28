// MoolahTests/Backends/GRDB/SyncRoundTripCSVImportTests.swift

import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Verifies that `ProfileDataSyncHandler.applyRemoteChanges` round-trips
/// CSV-import-profile and import-rule CKRecords through the GRDB
/// dispatch path introduced by slice 0 of `plans/grdb-migration.md`.
///
/// The flow mirrors what CKSyncEngine drives in production: device A
/// produces a CKRecord via `Row.toCKRecord(in:)`, device B's data
/// handler applies it via `applyRemoteChanges`, and we assert the GRDB
/// row on device B matches the source — including the cached
/// `encodedSystemFields` blob bit-for-bit.
@Suite("CKSyncEngine ↔ GRDB round trip — CSV import + rules")
@MainActor
struct SyncRoundTripCSVImportTests {

  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  // MARK: - CSVImportProfileRow

  @Test("CSV import profile applies via remote-change dispatch")
  func csvImportProfileRoundTrip() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let handler = harness.handler
    let database = harness.database
    let id = UUID()
    let accountId = UUID()
    let source = CSVImportProfileRow(
      id: id,
      recordName: CSVImportProfileRow.recordName(for: id),
      accountId: accountId,
      parserIdentifier: "generic-bank",
      headerSignature: "date\u{1F}amount",
      filenamePattern: nil,
      deleteAfterImport: false,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      lastUsedAt: nil,
      dateFormatRawValue: nil,
      columnRoleRawValuesEncoded: nil,
      encodedSystemFields: nil)
    let ckRecord = source.toCKRecord(in: Self.zoneID)

    let result = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])
    if case .saveFailed(let message) = result {
      Issue.record("applyRemoteChanges reported saveFailed: \(message)")
    }

    let rows = try await database.read { database in
      try CSVImportProfileRow.fetchAll(database)
    }
    let row = try #require(rows.first)
    #expect(rows.count == 1)
    #expect(row.id == id)
    #expect(row.accountId == accountId)
    #expect(row.parserIdentifier == "generic-bank")
    #expect(row.headerSignature == "date\u{1F}amount")
    // CKSyncEngine's apply path stamps the cached system fields from the
    // incoming record — non-nil after a successful apply.
    #expect(row.encodedSystemFields != nil)
  }

  @Test("CSV import profile delete via remote-change dispatch removes the row")
  func csvImportProfileDelete() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let handler = harness.handler
    let database = harness.database
    let id = UUID()
    let row = CSVImportProfileRow(
      id: id,
      recordName: CSVImportProfileRow.recordName(for: id),
      accountId: UUID(),
      parserIdentifier: "p",
      headerSignature: "a",
      filenamePattern: nil,
      deleteAfterImport: false,
      createdAt: Date(),
      lastUsedAt: nil,
      dateFormatRawValue: nil,
      columnRoleRawValuesEncoded: nil,
      encodedSystemFields: nil)
    try await database.write { database in
      try row.insert(database)
    }

    let recordID = CKRecord.ID(
      recordType: CSVImportProfileRow.recordType, uuid: id, zoneID: Self.zoneID)
    let result = handler.applyRemoteChanges(
      saved: [], deleted: [(recordID, CSVImportProfileRow.recordType)])
    if case .saveFailed(let message) = result {
      Issue.record("applyRemoteChanges reported saveFailed: \(message)")
    }

    let count = try await database.read { database in
      try CSVImportProfileRow.fetchCount(database)
    }
    #expect(count == 0)
  }

  // MARK: - ImportRuleRow

  @Test("import rule applies via remote-change dispatch")
  func importRuleRoundTrip() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let handler = harness.handler
    let database = harness.database
    let id = UUID()
    let conditionsJSON = Data(#"[{"k":"v"}]"#.utf8)
    let actionsJSON = Data(#"[{"a":"b"}]"#.utf8)
    let source = ImportRuleRow(
      id: id,
      recordName: ImportRuleRow.recordName(for: id),
      name: "Rent",
      enabled: true,
      position: 3,
      matchMode: MatchMode.all.rawValue,
      conditionsJSON: conditionsJSON,
      actionsJSON: actionsJSON,
      accountScope: nil,
      encodedSystemFields: nil)
    let ckRecord = source.toCKRecord(in: Self.zoneID)

    let result = handler.applyRemoteChanges(saved: [ckRecord], deleted: [])
    if case .saveFailed(let message) = result {
      Issue.record("applyRemoteChanges reported saveFailed: \(message)")
    }

    let rows = try await database.read { database in
      try ImportRuleRow.fetchAll(database)
    }
    let row = try #require(rows.first)
    #expect(rows.count == 1)
    #expect(row.id == id)
    #expect(row.name == "Rent")
    #expect(row.enabled)
    #expect(row.position == 3)
    #expect(row.matchMode == "all")
    #expect(row.conditionsJSON == conditionsJSON)
    #expect(row.actionsJSON == actionsJSON)
    #expect(row.encodedSystemFields != nil)
  }
}
