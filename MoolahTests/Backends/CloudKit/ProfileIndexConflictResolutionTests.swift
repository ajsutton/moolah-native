import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("ProfileIndexSyncHandler — dataFormatVersion conflict resolution")
struct ProfileIndexConflictResolutionTests {
  /// Bundles the handler, the backing repository, and a fresh profile id
  /// so the helper signature stays under SwiftLint's `large_tuple` ceiling.
  private struct Fixture {
    let handler: ProfileIndexSyncHandler
    let repository: GRDBProfileIndexRepository
    let id: UUID
  }

  private func makeFixture() throws -> Fixture {
    let database = try ProfileIndexDatabase.openInMemory()
    let repository = GRDBProfileIndexRepository(database: database)
    let handler = ProfileIndexSyncHandler(repository: repository)
    return Fixture(handler: handler, repository: repository, id: UUID())
  }

  private func makeServerRecord(
    id: UUID, dataFormatVersion: Int, in zoneID: CKRecordZone.ID
  ) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: ProfileRow.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: ProfileRow.recordType, recordID: recordID)
    record["createdAt"] = Date()
    record["currencyCode"] = "AUD"
    record["financialYearStartMonth"] = Int64(7)
    record["label"] = "Test"
    record["dataFormatVersion"] = Int64(dataFormatVersion)
    return record
  }

  @Test("server-higher case promotes local dataFormatVersion to the server's value")
  func serverHigherPromotes() async throws {
    let fixture = try makeFixture()
    try await fixture.repository.upsert(
      Profile(id: fixture.id, label: "Local", dataFormatVersion: 0))

    let serverRecord = makeServerRecord(
      id: fixture.id, dataFormatVersion: 1, in: fixture.handler.zoneID)
    fixture.handler.applyServerRecordChangedMerge(serverRecord: serverRecord)

    let merged = try await fixture.repository.profile(forID: fixture.id)
    #expect(merged?.dataFormatVersion == 1)
  }

  @Test("server-lower case keeps the higher local value — local is authoritative")
  func serverLowerKeepsLocal() async throws {
    let fixture = try makeFixture()
    try await fixture.repository.upsert(
      Profile(id: fixture.id, label: "Local", dataFormatVersion: 1))

    let serverRecord = makeServerRecord(
      id: fixture.id, dataFormatVersion: 0, in: fixture.handler.zoneID)
    fixture.handler.applyServerRecordChangedMerge(serverRecord: serverRecord)

    let merged = try await fixture.repository.profile(forID: fixture.id)
    #expect(merged?.dataFormatVersion == 1)
  }

  @Test("malformed recordID is a no-op (does not throw)")
  func malformedRecordIDIsNoOp() throws {
    let fixture = try makeFixture()
    // CKRecord whose recordName cannot be decoded as UUID — handler logs and returns.
    let bogus = CKRecord(
      recordType: ProfileRow.recordType,
      recordID: CKRecord.ID(recordName: "not-a-uuid", zoneID: fixture.handler.zoneID))
    fixture.handler.applyServerRecordChangedMerge(serverRecord: bogus)
    // Surviving the call without a throw is the assertion.
  }
}
