import CloudKit
import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("ProfileDataSyncHandler — record lookup")
@MainActor
struct ProfileDataSyncHandlerLookupTests {

  @Test
  func buildBatchRecordLookupFindsRecordsByUUID() throws {
    let (handler, container) = try ProfileDataSyncHandlerTestSupport.makeHandler()

    let accountId = UUID()
    let txnId = UUID()

    let context = ModelContext(container)
    context.insert(
      AccountRecord(id: accountId, name: "Acc", type: "bank", position: 0, isHidden: false))
    context.insert(
      TransactionRecord(id: txnId, date: Date(), payee: "Test"))
    try ProfileDataSyncHandlerTestSupport.saveAndMirror(context: context)

    let lookup = handler.buildBatchRecordLookup(byRecordType: [
      AccountRow.recordType: [accountId],
      TransactionRow.recordType: [txnId],
    ])

    #expect(lookup[AccountRow.recordType]?[accountId]?.recordType == "AccountRecord")
    #expect(lookup[TransactionRow.recordType]?[txnId]?.recordType == "TransactionRecord")
  }

  @Test
  func recordToSaveFindsAccountByUUID() throws {
    let (handler, container) = try ProfileDataSyncHandlerTestSupport.makeHandler()

    let accountId = UUID()
    let context = ModelContext(container)
    context.insert(
      AccountRecord(id: accountId, name: "Found", type: "bank", position: 0, isHidden: false))
    try ProfileDataSyncHandlerTestSupport.saveAndMirror(context: context)

    let recordID = CKRecord.ID(
      recordType: AccountRow.recordType, uuid: accountId, zoneID: handler.zoneID)
    let result = handler.recordToSave(for: recordID)
    #expect(result != nil)
    #expect(result?.recordType == "AccountRecord")
    #expect(result?["name"] as? String == "Found")
  }

  @Test
  func recordToSaveFindsInstrumentByStringID() throws {
    let (handler, container) = try ProfileDataSyncHandlerTestSupport.makeHandler()

    let context = ModelContext(container)
    context.insert(
      InstrumentRecord(
        id: "ASX:BHP.AX", kind: "stock", name: "BHP Group", decimals: 2,
        ticker: "BHP.AX", exchange: "ASX"))
    try ProfileDataSyncHandlerTestSupport.saveAndMirror(context: context)

    let recordID = CKRecord.ID(recordName: "ASX:BHP.AX", zoneID: handler.zoneID)
    let result = handler.recordToSave(for: recordID)
    #expect(result != nil)
    #expect(result?.recordType == "InstrumentRecord")
    #expect(result?["name"] as? String == "BHP Group")
  }

  @Test
  func recordToSaveReturnsNilForMissingRecord() throws {
    let (handler, _) = try ProfileDataSyncHandlerTestSupport.makeHandler()

    let recordID = CKRecord.ID(
      recordType: AccountRow.recordType, uuid: UUID(), zoneID: handler.zoneID)
    let result = handler.recordToSave(for: recordID)
    #expect(result == nil)
  }
}
