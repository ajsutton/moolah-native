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
    try context.save()

    let lookup = handler.buildBatchRecordLookup(byRecordType: [
      AccountRecord.recordType: [accountId],
      TransactionRecord.recordType: [txnId],
    ])

    #expect(lookup[AccountRecord.recordType]?[accountId]?.recordType == "CD_AccountRecord")
    #expect(lookup[TransactionRecord.recordType]?[txnId]?.recordType == "CD_TransactionRecord")
  }

  @Test
  func recordToSaveFindsAccountByUUID() throws {
    let (handler, container) = try ProfileDataSyncHandlerTestSupport.makeHandler()

    let accountId = UUID()
    let context = ModelContext(container)
    context.insert(
      AccountRecord(id: accountId, name: "Found", type: "bank", position: 0, isHidden: false))
    try context.save()

    let recordID = CKRecord.ID(
      recordType: AccountRecord.recordType, uuid: accountId, zoneID: handler.zoneID)
    let result = handler.recordToSave(for: recordID)
    #expect(result != nil)
    #expect(result?.recordType == "CD_AccountRecord")
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
    try context.save()

    let recordID = CKRecord.ID(recordName: "ASX:BHP.AX", zoneID: handler.zoneID)
    let result = handler.recordToSave(for: recordID)
    #expect(result != nil)
    #expect(result?.recordType == "CD_InstrumentRecord")
    #expect(result?["name"] as? String == "BHP Group")
  }

  @Test
  func recordToSaveReturnsNilForMissingRecord() throws {
    let (handler, _) = try ProfileDataSyncHandlerTestSupport.makeHandler()

    let recordID = CKRecord.ID(
      recordType: AccountRecord.recordType, uuid: UUID(), zoneID: handler.zoneID)
    let result = handler.recordToSave(for: recordID)
    #expect(result == nil)
  }
}
