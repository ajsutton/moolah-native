@preconcurrency import CloudKit
import Foundation
import Testing

@testable import Moolah

/// Pure-function tests for the legacy-`InstrumentRecord` pending-change
/// drain that runs at coordinator startup. Catches both the prefixed
/// `"InstrumentRecord|<UUID>"` form and the bare string-keyed legacy
/// shape (e.g. `"0:native"`, `"AUD"`) — the only legitimate path for
/// instrument writes is the shared registry on the profile-index zone,
/// so any pending change for an instrument on a per-profile zone is
/// leftover state that must be dropped before
/// `nextRecordZoneChangeBatch` materialises it and trips the DEBUG
/// `preconditionFailure` in `ProfileDataSyncHandler.recordToSave`.
@Suite("SyncCoordinator legacy-instrument drain")
struct SyncCoordinatorInstrumentDrainTests {

  // MARK: - Helpers

  private static func dataZone() -> CKRecordZone.ID {
    CKRecordZone.ID(
      zoneName: "profile-\(UUID().uuidString)",
      ownerName: CKCurrentUserDefaultName)
  }

  private static let indexZone = CKRecordZone.ID(
    zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)

  // MARK: - Match cases

  @Test("Drops bare string-keyed pending change on per-profile zone")
  func dropsBareStringKeyedOnDataZone() {
    let zone = Self.dataZone()
    let stale: CKSyncEngine.PendingRecordZoneChange =
      .saveRecord(CKRecord.ID(recordName: "0:native", zoneID: zone))
    let result = SyncCoordinator.legacyInstrumentPendingChanges(in: [stale])
    #expect(result.count == 1)
    #expect(result.first == stale)
  }

  @Test("Drops bare instrument-id pending change on per-profile zone")
  func dropsBareInstrumentIdOnDataZone() {
    let zone = Self.dataZone()
    let stale: CKSyncEngine.PendingRecordZoneChange =
      .saveRecord(CKRecord.ID(recordName: "AUD", zoneID: zone))
    let result = SyncCoordinator.legacyInstrumentPendingChanges(in: [stale])
    #expect(result.count == 1)
    #expect(result.first == stale)
  }

  @Test("Drops prefixed InstrumentRecord pending change on per-profile zone")
  func dropsPrefixedInstrumentOnDataZone() {
    let zone = Self.dataZone()
    let recordID = CKRecord.ID(
      recordName: "\(InstrumentRow.recordType)|\(UUID().uuidString)",
      zoneID: zone)
    let stale: CKSyncEngine.PendingRecordZoneChange = .saveRecord(recordID)
    let result = SyncCoordinator.legacyInstrumentPendingChanges(in: [stale])
    #expect(result.count == 1)
    #expect(result.first == stale)
  }

  @Test("Drops delete-flavoured legacy instrument pending change")
  func dropsDeleteFlavouredLegacyInstrument() {
    let zone = Self.dataZone()
    let stale: CKSyncEngine.PendingRecordZoneChange =
      .deleteRecord(CKRecord.ID(recordName: "0:native", zoneID: zone))
    let result = SyncCoordinator.legacyInstrumentPendingChanges(in: [stale])
    #expect(result == [stale])
  }

  // MARK: - Skip cases

  @Test("Keeps prefixed transaction-leg pending change on per-profile zone")
  func keepsPrefixedTransactionLegOnDataZone() {
    let zone = Self.dataZone()
    let recordID = CKRecord.ID(
      recordName: "\(TransactionLegRow.recordType)|\(UUID().uuidString)",
      zoneID: zone)
    let kept: CKSyncEngine.PendingRecordZoneChange = .saveRecord(recordID)
    let result = SyncCoordinator.legacyInstrumentPendingChanges(in: [kept])
    #expect(result.isEmpty)
  }

  @Test("Keeps prefixed InstrumentRecord pending change on profile-index zone")
  func keepsPrefixedInstrumentOnIndexZone() {
    let recordID = CKRecord.ID(
      recordName: "\(InstrumentRow.recordType)|\(UUID().uuidString)",
      zoneID: Self.indexZone)
    let kept: CKSyncEngine.PendingRecordZoneChange = .saveRecord(recordID)
    let result = SyncCoordinator.legacyInstrumentPendingChanges(in: [kept])
    #expect(result.isEmpty)
  }

  @Test("Keeps bare-UUID pending change (handled by sibling purge)")
  func keepsBareUUIDOnDataZone() {
    let zone = Self.dataZone()
    let kept: CKSyncEngine.PendingRecordZoneChange =
      .saveRecord(CKRecord.ID(recordName: UUID().uuidString, zoneID: zone))
    let result = SyncCoordinator.legacyInstrumentPendingChanges(in: [kept])
    #expect(result.isEmpty)
  }

  @Test("Keeps pending change on unknown-shaped zone")
  func keepsUnknownZone() {
    let zone = CKRecordZone.ID(
      zoneName: "some-other-zone", ownerName: CKCurrentUserDefaultName)
    let kept: CKSyncEngine.PendingRecordZoneChange =
      .saveRecord(CKRecord.ID(recordName: "0:native", zoneID: zone))
    let result = SyncCoordinator.legacyInstrumentPendingChanges(in: [kept])
    #expect(result.isEmpty)
  }

  // MARK: - Mixed input

  @Test("Returns only the legacy entries from a mixed input")
  func mixedInputReturnsOnlyLegacy() {
    let dataZone = Self.dataZone()
    let legacyBare: CKSyncEngine.PendingRecordZoneChange =
      .saveRecord(CKRecord.ID(recordName: "0:native", zoneID: dataZone))
    let legacyPrefixed: CKSyncEngine.PendingRecordZoneChange = .saveRecord(
      CKRecord.ID(
        recordName: "\(InstrumentRow.recordType)|\(UUID().uuidString)",
        zoneID: dataZone))
    let validLeg: CKSyncEngine.PendingRecordZoneChange = .saveRecord(
      CKRecord.ID(
        recordName: "\(TransactionLegRow.recordType)|\(UUID().uuidString)",
        zoneID: dataZone))
    let validIndexInstrument: CKSyncEngine.PendingRecordZoneChange = .saveRecord(
      CKRecord.ID(
        recordName: "\(InstrumentRow.recordType)|\(UUID().uuidString)",
        zoneID: Self.indexZone))
    let result = SyncCoordinator.legacyInstrumentPendingChanges(
      in: [legacyBare, validLeg, legacyPrefixed, validIndexInstrument])
    #expect(result.count == 2)
    #expect(result.contains(legacyBare))
    #expect(result.contains(legacyPrefixed))
  }

  @Test("Empty input returns empty")
  func emptyInputReturnsEmpty() {
    let result = SyncCoordinator.legacyInstrumentPendingChanges(in: [])
    #expect(result.isEmpty)
  }
}
