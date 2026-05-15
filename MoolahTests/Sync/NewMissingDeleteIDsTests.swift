// MoolahTests/Sync/NewMissingDeleteIDsTests.swift

@preconcurrency import CloudKit
import Foundation
import Testing

@testable import Moolah

/// Pure-helper tests for `SyncCoordinator.newMissingDeleteIDs(among:pendingChanges:)`.
///
/// The helper builds the `Set<CKRecord.ID>` from pending
/// `.deleteRecord` entries once and filters every candidate against the
/// set, so the main thread can drain a queue with tens of thousands of
/// stale records in linear time rather than O(candidates × pending).
@Suite("SyncCoordinator.newMissingDeleteIDs")
struct NewMissingDeleteIDsTests {

  private static let zone = CKRecordZone.ID(
    zoneName: "test-zone", ownerName: CKCurrentUserDefaultName)

  private static func recordID(_ name: String) -> CKRecord.ID {
    CKRecord.ID(recordName: name, zoneID: zone)
  }

  @Test("records already queued for deletion are excluded")
  func excludesIdsAlreadyPendingDelete() {
    let already = Self.recordID("already")
    let novel = Self.recordID("novel")
    let pending: [CKSyncEngine.PendingRecordZoneChange] = [.deleteRecord(already)]
    let result = SyncCoordinator.newMissingDeleteIDs(
      among: [already, novel], pendingChanges: pending)
    #expect(result == [novel])
  }

  @Test("pending .saveRecord entries do not shadow a candidate")
  func saveRecordDoesNotShadow() {
    let target = Self.recordID("target")
    let pending: [CKSyncEngine.PendingRecordZoneChange] = [.saveRecord(target)]
    let result = SyncCoordinator.newMissingDeleteIDs(
      among: [target], pendingChanges: pending)
    #expect(result == [target])
  }

  @Test("empty pending changes returns the input unchanged")
  func emptyPendingReturnsInput() {
    let first = Self.recordID("a")
    let second = Self.recordID("b")
    let result = SyncCoordinator.newMissingDeleteIDs(
      among: [first, second], pendingChanges: [])
    #expect(result == [first, second])
  }

  @Test("empty candidate list returns []")
  func emptyCandidatesReturnsEmpty() {
    let pending: [CKSyncEngine.PendingRecordZoneChange] = [
      .deleteRecord(Self.recordID("a"))
    ]
    let result = SyncCoordinator.newMissingDeleteIDs(
      among: [], pendingChanges: pending)
    #expect(result.isEmpty)
  }

  @Test("result preserves input order")
  func preservesInputOrder() {
    let first = Self.recordID("a")
    let second = Self.recordID("b")
    let third = Self.recordID("c")
    let result = SyncCoordinator.newMissingDeleteIDs(
      among: [third, first, second], pendingChanges: [])
    #expect(result == [third, first, second])
  }
}
