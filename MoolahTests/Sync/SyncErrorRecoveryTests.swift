import CloudKit
import Foundation
import Testing
import os

@testable import Moolah

@Suite("SyncErrorRecovery")
struct SyncErrorRecoveryTests {

  private static let logger = Logger(subsystem: "moolah.tests", category: "SyncErrorRecovery")

  private static let zoneID = CKRecordZone.ID(
    zoneName: "profile-\(UUID().uuidString)", ownerName: CKCurrentUserDefaultName)

  private static func makeRecordID(_ name: String = UUID().uuidString) -> CKRecord.ID {
    CKRecord.ID(recordName: name, zoneID: zoneID)
  }

  private static func makeCKError(_ code: CKError.Code) -> CKError {
    CKError(_nsError: NSError(domain: CKErrorDomain, code: code.rawValue))
  }

  // MARK: - Failed delete classification

  @Test func zoneNotFoundDeleteIsClassifiedForZoneCreation() {
    let recordID = Self.makeRecordID()
    let failures = SyncErrorRecovery.classify(
      failedSaves: [],
      failedDeletes: [(recordID, Self.makeCKError(.zoneNotFound))],
      logger: Self.logger)

    #expect(failures.zoneNotFoundDeletes == [recordID])
    #expect(failures.requeueDeletes.isEmpty)
  }

  @Test func userDeletedZoneDeleteIsClassifiedForZoneCreation() {
    let recordID = Self.makeRecordID()
    let failures = SyncErrorRecovery.classify(
      failedSaves: [],
      failedDeletes: [(recordID, Self.makeCKError(.userDeletedZone))],
      logger: Self.logger)

    #expect(failures.zoneNotFoundDeletes == [recordID])
    #expect(failures.requeueDeletes.isEmpty)
  }

  @Test func unknownItemDeleteIsTreatedAsSuccess() {
    // The record is already gone on the server — delete succeeded in effect.
    // It must NOT be re-queued (infinite loop) and NOT classified as zone-not-found.
    let recordID = Self.makeRecordID()
    let failures = SyncErrorRecovery.classify(
      failedSaves: [],
      failedDeletes: [(recordID, Self.makeCKError(.unknownItem))],
      logger: Self.logger)

    #expect(failures.zoneNotFoundDeletes.isEmpty)
    #expect(failures.requeueDeletes.isEmpty)
  }

  @Test func serverRecordChangedDeleteIsRequeued() {
    let recordID = Self.makeRecordID()
    let failures = SyncErrorRecovery.classify(
      failedSaves: [],
      failedDeletes: [(recordID, Self.makeCKError(.serverRecordChanged))],
      logger: Self.logger)

    #expect(failures.requeueDeletes == [recordID])
    #expect(failures.zoneNotFoundDeletes.isEmpty)
  }

  @Test func limitExceededDeleteIsRequeued() {
    let recordID = Self.makeRecordID()
    let failures = SyncErrorRecovery.classify(
      failedSaves: [],
      failedDeletes: [(recordID, Self.makeCKError(.limitExceeded))],
      logger: Self.logger)

    #expect(failures.requeueDeletes == [recordID])
  }

  @Test func unexpectedDeleteErrorIsRequeued() {
    let recordID = Self.makeRecordID()
    let failures = SyncErrorRecovery.classify(
      failedSaves: [],
      failedDeletes: [(recordID, Self.makeCKError(.internalError))],
      logger: Self.logger)

    #expect(failures.requeueDeletes == [recordID])
    #expect(failures.zoneNotFoundDeletes.isEmpty)
  }

  @Test func mixedDeleteFailuresAreRoutedIndependently() {
    let zoneMissing = Self.makeRecordID("zone-missing")
    let alreadyGone = Self.makeRecordID("already-gone")
    let conflict = Self.makeRecordID("conflict")
    let unexpected = Self.makeRecordID("unexpected")

    let failures = SyncErrorRecovery.classify(
      failedSaves: [],
      failedDeletes: [
        (zoneMissing, Self.makeCKError(.zoneNotFound)),
        (alreadyGone, Self.makeCKError(.unknownItem)),
        (conflict, Self.makeCKError(.serverRecordChanged)),
        (unexpected, Self.makeCKError(.internalError)),
      ],
      logger: Self.logger)

    #expect(failures.zoneNotFoundDeletes == [zoneMissing])
    #expect(Set(failures.requeueDeletes) == [conflict, unexpected])
  }
}
