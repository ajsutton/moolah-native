// MoolahTests/Backends/GRDB/GRDBProfileIndexRepositoryTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Contract tests for `GRDBProfileIndexRepository`. The repo has no
/// domain protocol (the profile-index DB is an app-level concern, not
/// a per-profile data concern), so these tests drive the GRDB
/// implementation directly via the in-memory factory.
@Suite("GRDBProfileIndexRepository contract")
struct GRDBProfileIndexRepositoryTests {

  // MARK: - Factory

  private func makeRepo() throws -> GRDBProfileIndexRepository {
    let database = try ProfileIndexDatabase.openInMemory()
    return GRDBProfileIndexRepository(database: database)
  }

  private func makeProfile(
    label: String,
    createdAt: Date
  ) -> Profile {
    Profile(
      id: UUID(),
      label: label,
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      createdAt: createdAt)
  }

  // MARK: - 1. fetchAll / upsert / delete round-trip

  @Test("fetchAll, upsert, delete round-trip")
  func roundTrip() async throws {
    let repo = try makeRepo()
    let earlier = makeProfile(
      label: "Personal", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    let later = makeProfile(
      label: "Business", createdAt: Date(timeIntervalSince1970: 1_710_000_000))

    try await repo.upsert(earlier)
    try await repo.upsert(later)

    let all = try await repo.fetchAll()
    #expect(all.count == 2)
    #expect(all[0].id == earlier.id)
    #expect(all[1].id == later.id)
    #expect(all[0].label == "Personal")
    #expect(all[1].label == "Business")

    let didDelete = try await repo.delete(id: earlier.id)
    #expect(didDelete)
    let remaining = try await repo.fetchAll()
    #expect(remaining.count == 1)
    #expect(remaining[0].id == later.id)
  }

  // MARK: - 2. upsert preserves encodedSystemFields

  @Test("upsert preserves encodedSystemFields when row already exists")
  func upsertPreservesEncodedSystemFields() async throws {
    let repo = try makeRepo()
    let id = UUID()
    let blob = Data([0xAA, 0xBB, 0xCC])
    // Seed a row with a non-nil system-fields blob via the sync entry
    // point — that's the path the CKSyncEngine uses to stamp the
    // change tag.
    let seeded = ProfileRow(
      id: id,
      recordName: ProfileRow.recordName(for: id),
      label: "Seeded",
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      encodedSystemFields: blob)
    try repo.applyRemoteChangesSync(saved: [seeded], deleted: [])

    // Now drive a domain-side upsert with the same id and a different
    // label. The mapping helper builds a row with `encodedSystemFields
    // = nil`; the repo must inherit the existing blob inside its
    // write closure.
    let domain = Profile(
      id: id,
      label: "Renamed",
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    try await repo.upsert(domain)

    let row = try #require(try repo.fetchRowSync(id: id))
    #expect(row.label == "Renamed")
    #expect(row.encodedSystemFields == blob)
  }

  // MARK: - 3. applyRemoteChangesSync upsert + delete

  @Test("applyRemoteChangesSync applies saves and deletes atomically")
  func applyRemoteChangesUpsertAndDelete() async throws {
    let repo = try makeRepo()
    let firstId = UUID()
    let secondId = UUID()
    let firstSeed = ProfileRow(
      id: firstId,
      recordName: ProfileRow.recordName(for: firstId),
      label: "First",
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      encodedSystemFields: nil)
    let secondSeed = ProfileRow(
      id: secondId,
      recordName: ProfileRow.recordName(for: secondId),
      label: "Second",
      currencyCode: "USD",
      financialYearStartMonth: 1,
      createdAt: Date(timeIntervalSince1970: 1_710_000_000),
      encodedSystemFields: nil)
    try repo.applyRemoteChangesSync(saved: [firstSeed, secondSeed], deleted: [])

    let afterSave = try repo.allRowIdsSync()
    #expect(Set(afterSave) == Set([firstId, secondId]))

    // Second pass: a save (mutating `firstSeed`) and a delete of
    // `secondId`. Confirms both halves of the same write transaction
    // land.
    var firstUpdated = firstSeed
    firstUpdated.label = "First Renamed"
    try repo.applyRemoteChangesSync(saved: [firstUpdated], deleted: [secondId])

    let afterMixed = try repo.allRowIdsSync()
    #expect(afterMixed == [firstId])
    let row = try #require(try repo.fetchRowSync(id: firstId))
    #expect(row.label == "First Renamed")
  }

  // MARK: - 4. setEncodedSystemFieldsSync writes and clears

  @Test("setEncodedSystemFieldsSync writes and clears")
  func setEncodedSystemFieldsWritesAndClears() async throws {
    let repo = try makeRepo()
    let profile = makeProfile(
      label: "Personal", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    try await repo.upsert(profile)

    let blob = Data([0x01, 0x02, 0x03, 0x04])
    let didWrite = try repo.setEncodedSystemFieldsSync(id: profile.id, data: blob)
    #expect(didWrite)
    var row = try #require(try repo.fetchRowSync(id: profile.id))
    #expect(row.encodedSystemFields == blob)

    let didClear = try repo.setEncodedSystemFieldsSync(id: profile.id, data: nil)
    #expect(didClear)
    row = try #require(try repo.fetchRowSync(id: profile.id))
    #expect(row.encodedSystemFields == nil)

    // Missing id → no row matched, returns false.
    let didMatchMissing = try repo.setEncodedSystemFieldsSync(id: UUID(), data: blob)
    #expect(!didMatchMissing)
  }

  // MARK: - 5. clearAllSystemFieldsSync nulls every blob

  @Test("clearAllSystemFieldsSync nulls every row's blob")
  func clearAllSystemFieldsNullsEveryRow() async throws {
    let repo = try makeRepo()
    let firstId = UUID()
    let secondId = UUID()
    let blob = Data([0xFF])
    let firstSeed = ProfileRow(
      id: firstId,
      recordName: ProfileRow.recordName(for: firstId),
      label: "First",
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      encodedSystemFields: blob)
    let secondSeed = ProfileRow(
      id: secondId,
      recordName: ProfileRow.recordName(for: secondId),
      label: "Second",
      currencyCode: "USD",
      financialYearStartMonth: 1,
      createdAt: Date(timeIntervalSince1970: 1_710_000_000),
      encodedSystemFields: blob)
    try repo.applyRemoteChangesSync(saved: [firstSeed, secondSeed], deleted: [])

    try repo.clearAllSystemFieldsSync()

    let firstRow = try #require(try repo.fetchRowSync(id: firstId))
    let secondRow = try #require(try repo.fetchRowSync(id: secondId))
    #expect(firstRow.encodedSystemFields == nil)
    #expect(secondRow.encodedSystemFields == nil)
  }

  // MARK: - 6. delete return value

  @Test("delete returns true when row existed, false otherwise")
  func deleteReturnValue() async throws {
    let repo = try makeRepo()
    let profile = makeProfile(
      label: "Personal", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    try await repo.upsert(profile)

    let didDelete = try await repo.delete(id: profile.id)
    #expect(didDelete)

    let didDeleteAgain = try await repo.delete(id: profile.id)
    #expect(!didDeleteAgain)

    let didDeleteMissing = try await repo.delete(id: UUID())
    #expect(!didDeleteMissing)
  }

  // MARK: - 7. attachSyncHooks installs hooks atomically

  @Test("attachSyncHooks fires after install, not before")
  func attachSyncHooksFiresAfterInstall() async throws {
    let repo = try makeRepo()

    let firstProfile = makeProfile(
      label: "Before", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    // No hooks attached yet — this upsert must NOT fire the (default
    // no-op) hooks. We exercise the path to confirm it's a no-op.
    try await repo.upsert(firstProfile)

    let changedCount = LockedBox<Int>(0)
    let deletedCount = LockedBox<Int>(0)

    repo.attachSyncHooks(
      onRecordChanged: { _ in changedCount.set(changedCount.get() + 1) },
      onRecordDeleted: { _ in deletedCount.set(deletedCount.get() + 1) })

    // After install, an upsert fires `onRecordChanged` exactly once.
    let secondProfile = makeProfile(
      label: "After", createdAt: Date(timeIntervalSince1970: 1_710_000_000))
    try await repo.upsert(secondProfile)
    #expect(changedCount.get() == 1)
    #expect(deletedCount.get() == 0)

    // A delete fires `onRecordDeleted` exactly once.
    _ = try await repo.delete(id: secondProfile.id)
    #expect(changedCount.get() == 1)
    #expect(deletedCount.get() == 1)

    // A delete that doesn't match a row does NOT fire the hook.
    _ = try await repo.delete(id: UUID())
    #expect(deletedCount.get() == 1)
  }
}
