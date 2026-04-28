import CloudKit
import Foundation
import SwiftData
import Testing

@testable import Moolah

/// Verifies that `ProfileDataSyncHandler.applyRemoteChanges` fires the
/// `onInstrumentRemoteChange` closure whenever a remote pull touches an
/// `InstrumentRecord` row (either via upsert or via deletion), and only
/// then. This is the sync-side fan-out that lets the picker UI's
/// `observeChanges()` subscribers refresh after a token registered on
/// another device arrives — without it, the registry's notify path only
/// fires for local writes.
@Suite("ProfileDataSyncHandler — onInstrumentRemoteChange fan-out")
@MainActor
struct InstrumentRemoteChangeFanOutTests {

  // MARK: - Helpers

  /// Builds a handler whose `onInstrumentRemoteChange` closure increments
  /// the supplied `LockedBox<Int>` every time it fires. Returns the handler
  /// and its model container so tests can drive `applyRemoteChanges`
  /// directly, mirroring the existing per-handler tests in this folder.
  private func makeHandler(
    fired: LockedBox<Int>
  ) throws -> (ProfileDataSyncHandler, ModelContainer) {
    let container = try TestModelContainer.create()
    let profileId = UUID()
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profileId.uuidString)",
      ownerName: CKCurrentUserDefaultName
    )
    let handler = ProfileDataSyncHandler(
      profileId: profileId,
      zoneID: zoneID,
      modelContainer: container,
      onInstrumentRemoteChange: {
        fired.set(fired.get() + 1)
      }
    )
    return (handler, container)
  }

  private func makeInstrumentRecord(
    id: String, in zoneID: CKRecordZone.ID
  ) -> CKRecord {
    let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
    let record = CKRecord(recordType: InstrumentRecord.recordType, recordID: recordID)
    record["kind"] = "cryptoToken" as CKRecordValue
    record["name"] = "Uniswap" as CKRecordValue
    record["decimals"] = 18 as CKRecordValue
    record["coingeckoId"] = "uniswap" as CKRecordValue
    return record
  }

  private func makeAccountRecord(
    in zoneID: CKRecordZone.ID
  ) -> CKRecord {
    let accountId = UUID()
    let recordID = CKRecord.ID(
      recordType: AccountRecord.recordType, uuid: accountId, zoneID: zoneID)
    let record = CKRecord(recordType: AccountRecord.recordType, recordID: recordID)
    record["name"] = "Checking" as CKRecordValue
    record["type"] = "bank" as CKRecordValue
    record["position"] = 0 as CKRecordValue
    record["isHidden"] = 0 as CKRecordValue
    return record
  }

  // MARK: - Tests

  @Test("Remote upsert of an instrument fires the closure exactly once")
  func remoteUpsertOfInstrumentFiresClosure() throws {
    let fired = LockedBox(0)
    let (handler, _) = try makeHandler(fired: fired)
    let record = makeInstrumentRecord(id: "1:0xuni", in: handler.zoneID)

    let result = handler.applyRemoteChanges(saved: [record], deleted: [])

    guard case .success = result else {
      Issue.record("Expected .success but got \(result)")
      return
    }
    #expect(fired.get() == 1)
  }

  @Test("A multi-instrument batch still fires the closure exactly once")
  func multiInstrumentBatchFiresClosureOnce() throws {
    let fired = LockedBox(0)
    let (handler, _) = try makeHandler(fired: fired)
    let first = makeInstrumentRecord(id: "1:0xuni", in: handler.zoneID)
    let second = makeInstrumentRecord(id: "1:0xaave", in: handler.zoneID)

    _ = handler.applyRemoteChanges(saved: [first, second], deleted: [])

    #expect(fired.get() == 1)
  }

  @Test("Remote upsert of a non-instrument record does not fire the closure")
  func remoteUpsertOfNonInstrumentDoesNotFireClosure() throws {
    let fired = LockedBox(0)
    let (handler, _) = try makeHandler(fired: fired)
    let record = makeAccountRecord(in: handler.zoneID)

    _ = handler.applyRemoteChanges(saved: [record], deleted: [])

    #expect(fired.get() == 0)
  }

  @Test("Remote deletion of an instrument fires the closure exactly once")
  func remoteDeletionOfInstrumentFiresClosure() throws {
    let fired = LockedBox(0)
    let (handler, container) = try makeHandler(fired: fired)
    // Seed an instrument so the deletion has something to remove. The
    // closure must still fire even if the row is already absent locally,
    // but seeding lets us also verify the row is gone after the call.
    let context = ModelContext(container)
    context.insert(
      InstrumentRecord(
        id: "1:0xuni", kind: "cryptoToken", name: "Uniswap", decimals: 18))
    try context.save()

    let recordID = CKRecord.ID(recordName: "1:0xuni", zoneID: handler.zoneID)
    let result = handler.applyRemoteChanges(
      saved: [],
      deleted: [(recordID, InstrumentRecord.recordType)]
    )

    guard case .success = result else {
      Issue.record("Expected .success but got \(result)")
      return
    }
    #expect(fired.get() == 1)
  }

  @Test("Remote deletion of a non-instrument record does not fire the closure")
  func remoteDeletionOfNonInstrumentDoesNotFireClosure() throws {
    let fired = LockedBox(0)
    let (handler, _) = try makeHandler(fired: fired)
    let recordID = CKRecord.ID(
      recordType: AccountRecord.recordType, uuid: UUID(), zoneID: handler.zoneID)

    _ = handler.applyRemoteChanges(
      saved: [],
      deleted: [(recordID, AccountRecord.recordType)]
    )

    #expect(fired.get() == 0)
  }
}
