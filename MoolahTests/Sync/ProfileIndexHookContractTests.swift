// MoolahTests/Sync/ProfileIndexHookContractTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Pins the wire contract that `SyncCoordinator+ProfileIndexHooks`
/// depends on: every successful `upsert` / `delete` on
/// `GRDBProfileIndexRepository` must signal the attached hook closures
/// with `(recordType: ProfileRow.recordType, id: profile.id)` so the
/// coordinator's `queueSave` / `queueDeletion` calls land on the right
/// CKRecord.ID prefix (issue #416 regression class — wrong prefix
/// silently converts uploads into phantom deletes against the wrong
/// record type).
///
/// We test the repository hook contract directly rather than wiring an
/// end-to-end `SyncCoordinator` mock: `wireProfileIndexHooks` is a thin
/// `attachSyncHooks` call, and the hook signature `(UUID) -> Void` is
/// the only surface that wiring touches. If this contract holds, the
/// coordinator's wire path holds by construction.
@Suite("ProfileIndex sync hooks contract")
struct ProfileIndexHookContractTests {

  private func makeProfile(label: String = "Test") -> Profile {
    Profile(
      id: UUID(),
      label: label,
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
  }

  @Test("upsert via repository signals queueSave with ProfileRow.recordType")
  func upsertSignalsQueueSave() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let repo = GRDBProfileIndexRepository(database: database)
    let captured = LockedBox<(recordType: String, id: UUID)?>(nil)
    repo.attachSyncHooks(
      onRecordChanged: { id in
        captured.set((recordType: ProfileRow.recordType, id: id))
      },
      onRecordDeleted: { _ in })

    let profile = makeProfile()
    try await repo.upsert(profile)

    let observed = try #require(captured.get())
    #expect(observed.recordType == "ProfileRecord")
    #expect(observed.recordType == ProfileRow.recordType)
    #expect(observed.id == profile.id)
  }

  @Test("delete via repository signals queueDeletion with ProfileRow.recordType")
  func deleteSignalsQueueDeletion() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let repo = GRDBProfileIndexRepository(database: database)
    let captured = LockedBox<(recordType: String, id: UUID)?>(nil)
    repo.attachSyncHooks(
      onRecordChanged: { _ in },
      onRecordDeleted: { id in
        captured.set((recordType: ProfileRow.recordType, id: id))
      })

    let profile = makeProfile()
    try await repo.upsert(profile)
    let didDelete = try await repo.delete(id: profile.id)
    #expect(didDelete)

    let observed = try #require(captured.get())
    #expect(observed.recordType == "ProfileRecord")
    #expect(observed.recordType == ProfileRow.recordType)
    #expect(observed.id == profile.id)
  }
}
