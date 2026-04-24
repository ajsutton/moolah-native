import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("RecordMapping")
struct RecordMappingTests {

  let zoneID = CKRecordZone.ID(zoneName: "profile-test", ownerName: CKCurrentUserDefaultName)

  // MARK: - ProfileRecord

  @Test
  func profileRecordRoundTrip() {
    let profile = ProfileRecord(
      id: UUID(),
      label: "My Budget",
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let ckRecord = profile.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "CD_ProfileRecord")
    #expect(
      ckRecord.recordID.recordName
        == "\(ProfileRecord.recordType)|\(profile.id.uuidString)")
    #expect(ckRecord.recordID.zoneID == zoneID)
    #expect(ckRecord["label"] as? String == "My Budget")
    #expect(ckRecord["currencyCode"] as? String == "AUD")
    #expect(ckRecord["financialYearStartMonth"] as? Int == 7)
    #expect(ckRecord["createdAt"] as? Date == profile.createdAt)

    let restored = ProfileRecord.fieldValues(from: ckRecord)
    #expect(restored.id == profile.id)
    #expect(restored.label == "My Budget")
    #expect(restored.currencyCode == "AUD")
    #expect(restored.financialYearStartMonth == 7)
    #expect(restored.createdAt == profile.createdAt)
  }

  // MARK: - AccountRecord

  @Test
  func accountRecordRoundTrip() {
    let account = AccountRecord(
      id: UUID(),
      name: "Savings",
      type: "bank",
      instrumentId: "USD",
      position: 2,
      isHidden: true
    )

    let ckRecord = account.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "CD_AccountRecord")
    #expect(
      ckRecord.recordID.recordName
        == "\(AccountRecord.recordType)|\(account.id.uuidString)")
    #expect(ckRecord["name"] as? String == "Savings")
    #expect(ckRecord["type"] as? String == "bank")
    #expect(ckRecord["instrumentId"] as? String == "USD")
    #expect(ckRecord["position"] as? Int == 2)
    #expect(ckRecord["isHidden"] as? Int == 1)

    let restored = AccountRecord.fieldValues(from: ckRecord)
    #expect(restored.id == account.id)
    #expect(restored.name == "Savings")
    #expect(restored.type == "bank")
    #expect(restored.instrumentId == "USD")
    #expect(restored.position == 2)
    #expect(restored.isHidden == true)
  }

  @Test
  func accountRecordFieldValuesDefaultsInstrumentId() {
    // When instrumentId is missing from CKRecord, default to "AUD"
    let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
    let ckRecord = CKRecord(recordType: "CD_AccountRecord", recordID: recordID)
    ckRecord["name"] = "Test" as CKRecordValue
    ckRecord["type"] = "bank" as CKRecordValue
    // No instrumentId set

    let restored = AccountRecord.fieldValues(from: ckRecord)
    #expect(restored.instrumentId == "AUD")
  }

  // MARK: - TransactionRecord

  @Test
  func transactionRecordRoundTrip() {
    let txnDate = Date(timeIntervalSince1970: 1_700_000_000)

    let txn = TransactionRecord(
      id: UUID(),
      date: txnDate,
      payee: "Rent",
      notes: "Monthly rent",
      recurPeriod: "monthly",
      recurEvery: 1
    )

    let ckRecord = txn.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "CD_TransactionRecord")
    #expect(
      ckRecord.recordID.recordName
        == "\(TransactionRecord.recordType)|\(txn.id.uuidString)")
    #expect(ckRecord["date"] as? Date == txnDate)
    #expect(ckRecord["payee"] as? String == "Rent")
    #expect(ckRecord["notes"] as? String == "Monthly rent")
    #expect(ckRecord["recurPeriod"] as? String == "monthly")
    #expect(ckRecord["recurEvery"] as? Int == 1)

    let restored = TransactionRecord.fieldValues(from: ckRecord)
    #expect(restored.id == txn.id)
    #expect(restored.date == txnDate)
    #expect(restored.payee == "Rent")
    #expect(restored.notes == "Monthly rent")
    #expect(restored.recurPeriod == "monthly")
    #expect(restored.recurEvery == 1)
  }

  @Test
  func transactionRecordNilOptionals() {
    let txn = TransactionRecord(
      id: UUID(),
      date: Date()
    )

    let ckRecord = txn.toCKRecord(in: zoneID)
    #expect(ckRecord["payee"] == nil)
    #expect(ckRecord["notes"] == nil)
    #expect(ckRecord["recurPeriod"] == nil)
    #expect(ckRecord["recurEvery"] == nil)

    let restored = TransactionRecord.fieldValues(from: ckRecord)
    #expect(restored.payee == nil)
    #expect(restored.notes == nil)
    #expect(restored.recurPeriod == nil)
    #expect(restored.recurEvery == nil)
  }

  // MARK: - TransactionLegRecord

  @Test
  func transactionLegRecordRoundTrip() {
    let transactionId = UUID()
    let accountId = UUID()
    let categoryId = UUID()
    let earmarkId = UUID()

    let leg = TransactionLegRecord(
      id: UUID(),
      transactionId: transactionId,
      accountId: accountId,
      instrumentId: "AUD",
      quantity: 500_000_000,
      type: "expense",
      categoryId: categoryId,
      earmarkId: earmarkId,
      sortOrder: 0
    )

    let ckRecord = leg.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "CD_TransactionLegRecord")
    #expect(
      ckRecord.recordID.recordName
        == "\(TransactionLegRecord.recordType)|\(leg.id.uuidString)")
    #expect(ckRecord["transactionId"] as? String == transactionId.uuidString)
    #expect(ckRecord["accountId"] as? String == accountId.uuidString)
    #expect(ckRecord["instrumentId"] as? String == "AUD")
    #expect(ckRecord["quantity"] as? Int64 == 500_000_000)
    #expect(ckRecord["type"] as? String == "expense")
    #expect(ckRecord["categoryId"] as? String == categoryId.uuidString)
    #expect(ckRecord["earmarkId"] as? String == earmarkId.uuidString)
    #expect(ckRecord["sortOrder"] as? Int == 0)

    let restored = TransactionLegRecord.fieldValues(from: ckRecord)
    #expect(restored.id == leg.id)
    #expect(restored.transactionId == transactionId)
    #expect(restored.accountId == accountId)
    #expect(restored.instrumentId == "AUD")
    #expect(restored.quantity == 500_000_000)
    #expect(restored.type == "expense")
    #expect(restored.categoryId == categoryId)
    #expect(restored.earmarkId == earmarkId)
    #expect(restored.sortOrder == 0)
  }
}
