import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("RecordMapping")
struct RecordMappingTests {

  let zoneID = CKRecordZone.ID(zoneName: "profile-test", ownerName: CKCurrentUserDefaultName)

  // MARK: - ProfileRecord

  @Test func profileRecordRoundTrip() {
    let profile = ProfileRecord(
      id: UUID(),
      label: "My Budget",
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let ckRecord = profile.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "CD_ProfileRecord")
    #expect(ckRecord.recordID.recordName == profile.id.uuidString)
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

  @Test func accountRecordRoundTrip() {
    let account = AccountRecord(
      id: UUID(),
      name: "Savings",
      type: "bank",
      position: 2,
      isHidden: true,
      currencyCode: "USD",
      cachedBalance: 12345
    )

    let ckRecord = account.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "CD_AccountRecord")
    #expect(ckRecord.recordID.recordName == account.id.uuidString)
    #expect(ckRecord["name"] as? String == "Savings")
    #expect(ckRecord["type"] as? String == "bank")
    #expect(ckRecord["position"] as? Int == 2)
    #expect(ckRecord["isHidden"] as? Int == 1)
    #expect(ckRecord["currencyCode"] as? String == "USD")
    // cachedBalance is NOT synced — it's derived locally from transactions
    #expect(ckRecord["cachedBalance"] == nil)

    let restored = AccountRecord.fieldValues(from: ckRecord)
    #expect(restored.id == account.id)
    #expect(restored.name == "Savings")
    #expect(restored.type == "bank")
    #expect(restored.position == 2)
    #expect(restored.isHidden == true)
    #expect(restored.currencyCode == "USD")
    #expect(restored.cachedBalance == nil)
  }

  @Test func accountRecordNilCachedBalance() {
    let account = AccountRecord(
      id: UUID(),
      name: "Checking",
      type: "bank",
      position: 0,
      isHidden: false,
      currencyCode: "AUD",
      cachedBalance: nil
    )

    let ckRecord = account.toCKRecord(in: zoneID)
    #expect(ckRecord["cachedBalance"] == nil)

    let restored = AccountRecord.fieldValues(from: ckRecord)
    #expect(restored.cachedBalance == nil)
  }

  // MARK: - TransactionRecord

  @Test func transactionRecordRoundTrip() {
    let txnDate = Date(timeIntervalSince1970: 1_700_000_000)
    let accountId = UUID()
    let toAccountId = UUID()
    let categoryId = UUID()
    let earmarkId = UUID()

    let txn = TransactionRecord(
      id: UUID(),
      type: "transfer",
      date: txnDate,
      accountId: accountId,
      toAccountId: toAccountId,
      amount: -5000,
      currencyCode: "AUD",
      payee: "Rent",
      notes: "Monthly rent",
      categoryId: categoryId,
      earmarkId: earmarkId,
      recurPeriod: "monthly",
      recurEvery: 1
    )

    let ckRecord = txn.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "CD_TransactionRecord")
    #expect(ckRecord.recordID.recordName == txn.id.uuidString)
    #expect(ckRecord["type"] as? String == "transfer")
    #expect(ckRecord["date"] as? Date == txnDate)
    #expect(ckRecord["accountId"] as? String == accountId.uuidString)
    #expect(ckRecord["toAccountId"] as? String == toAccountId.uuidString)
    #expect(ckRecord["amount"] as? Int == -5000)
    #expect(ckRecord["currencyCode"] as? String == "AUD")
    #expect(ckRecord["payee"] as? String == "Rent")
    #expect(ckRecord["notes"] as? String == "Monthly rent")
    #expect(ckRecord["categoryId"] as? String == categoryId.uuidString)
    #expect(ckRecord["earmarkId"] as? String == earmarkId.uuidString)
    #expect(ckRecord["recurPeriod"] as? String == "monthly")
    #expect(ckRecord["recurEvery"] as? Int == 1)

    let restored = TransactionRecord.fieldValues(from: ckRecord)
    #expect(restored.id == txn.id)
    #expect(restored.type == "transfer")
    #expect(restored.date == txnDate)
    #expect(restored.accountId == accountId)
    #expect(restored.toAccountId == toAccountId)
    #expect(restored.amount == -5000)
    #expect(restored.currencyCode == "AUD")
    #expect(restored.payee == "Rent")
    #expect(restored.notes == "Monthly rent")
    #expect(restored.categoryId == categoryId)
    #expect(restored.earmarkId == earmarkId)
    #expect(restored.recurPeriod == "monthly")
    #expect(restored.recurEvery == 1)
  }

  @Test func transactionRecordNilOptionals() {
    let txn = TransactionRecord(
      id: UUID(),
      type: "expense",
      date: Date(),
      accountId: nil,
      toAccountId: nil,
      amount: 100,
      currencyCode: "AUD",
      payee: nil,
      notes: nil,
      categoryId: nil,
      earmarkId: nil,
      recurPeriod: nil,
      recurEvery: nil
    )

    let ckRecord = txn.toCKRecord(in: zoneID)
    #expect(ckRecord["accountId"] == nil)
    #expect(ckRecord["toAccountId"] == nil)
    #expect(ckRecord["payee"] == nil)
    #expect(ckRecord["notes"] == nil)
    #expect(ckRecord["categoryId"] == nil)
    #expect(ckRecord["earmarkId"] == nil)
    #expect(ckRecord["recurPeriod"] == nil)
    #expect(ckRecord["recurEvery"] == nil)

    let restored = TransactionRecord.fieldValues(from: ckRecord)
    #expect(restored.accountId == nil)
    #expect(restored.toAccountId == nil)
    #expect(restored.payee == nil)
    #expect(restored.notes == nil)
    #expect(restored.categoryId == nil)
    #expect(restored.earmarkId == nil)
    #expect(restored.recurPeriod == nil)
    #expect(restored.recurEvery == nil)
  }

  // MARK: - CategoryRecord

  @Test func categoryRecordRoundTrip() {
    let parentId = UUID()
    let category = CategoryRecord(id: UUID(), name: "Food", parentId: parentId)

    let ckRecord = category.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "CD_CategoryRecord")
    #expect(ckRecord["name"] as? String == "Food")
    #expect(ckRecord["parentId"] as? String == parentId.uuidString)

    let restored = CategoryRecord.fieldValues(from: ckRecord)
    #expect(restored.id == category.id)
    #expect(restored.name == "Food")
    #expect(restored.parentId == parentId)
  }

  @Test func categoryRecordNilParent() {
    let category = CategoryRecord(id: UUID(), name: "Root", parentId: nil)

    let ckRecord = category.toCKRecord(in: zoneID)
    #expect(ckRecord["parentId"] == nil)

    let restored = CategoryRecord.fieldValues(from: ckRecord)
    #expect(restored.parentId == nil)
  }

  // MARK: - EarmarkRecord

  @Test func earmarkRecordRoundTrip() {
    let startDate = Date(timeIntervalSince1970: 1_700_000_000)
    let endDate = Date(timeIntervalSince1970: 1_710_000_000)
    let earmark = EarmarkRecord(
      id: UUID(),
      name: "Holiday Fund",
      position: 3,
      isHidden: false,
      savingsTarget: 500_000,
      currencyCode: "AUD",
      savingsStartDate: startDate,
      savingsEndDate: endDate
    )

    let ckRecord = earmark.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "CD_EarmarkRecord")
    #expect(ckRecord["name"] as? String == "Holiday Fund")
    #expect(ckRecord["position"] as? Int == 3)
    #expect(ckRecord["isHidden"] as? Int == 0)
    #expect(ckRecord["savingsTarget"] as? Int == 500_000)
    #expect(ckRecord["currencyCode"] as? String == "AUD")
    #expect(ckRecord["savingsStartDate"] as? Date == startDate)
    #expect(ckRecord["savingsEndDate"] as? Date == endDate)

    let restored = EarmarkRecord.fieldValues(from: ckRecord)
    #expect(restored.id == earmark.id)
    #expect(restored.name == "Holiday Fund")
    #expect(restored.position == 3)
    #expect(restored.isHidden == false)
    #expect(restored.savingsTarget == 500_000)
    #expect(restored.currencyCode == "AUD")
    #expect(restored.savingsStartDate == startDate)
    #expect(restored.savingsEndDate == endDate)
  }

  @Test func earmarkRecordNilOptionals() {
    let earmark = EarmarkRecord(
      id: UUID(),
      name: "Basic",
      position: 0,
      isHidden: false,
      savingsTarget: nil,
      currencyCode: "AUD",
      savingsStartDate: nil,
      savingsEndDate: nil
    )

    let ckRecord = earmark.toCKRecord(in: zoneID)
    #expect(ckRecord["savingsTarget"] == nil)
    #expect(ckRecord["savingsStartDate"] == nil)
    #expect(ckRecord["savingsEndDate"] == nil)

    let restored = EarmarkRecord.fieldValues(from: ckRecord)
    #expect(restored.savingsTarget == nil)
    #expect(restored.savingsStartDate == nil)
    #expect(restored.savingsEndDate == nil)
  }

  // MARK: - EarmarkBudgetItemRecord

  @Test func earmarkBudgetItemRecordRoundTrip() {
    let earmarkId = UUID()
    let categoryId = UUID()
    let item = EarmarkBudgetItemRecord(
      id: UUID(),
      earmarkId: earmarkId,
      categoryId: categoryId,
      amount: 10000,
      currencyCode: "AUD"
    )

    let ckRecord = item.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "CD_EarmarkBudgetItemRecord")
    #expect(ckRecord["earmarkId"] as? String == earmarkId.uuidString)
    #expect(ckRecord["categoryId"] as? String == categoryId.uuidString)
    #expect(ckRecord["amount"] as? Int == 10000)
    #expect(ckRecord["currencyCode"] as? String == "AUD")

    let restored = EarmarkBudgetItemRecord.fieldValues(from: ckRecord)
    #expect(restored.id == item.id)
    #expect(restored.earmarkId == earmarkId)
    #expect(restored.categoryId == categoryId)
    #expect(restored.amount == 10000)
    #expect(restored.currencyCode == "AUD")
  }

  // MARK: - InvestmentValueRecord

  @Test func investmentValueRecordRoundTrip() {
    let accountId = UUID()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let record = InvestmentValueRecord(
      id: UUID(),
      accountId: accountId,
      date: date,
      value: 250_000,
      currencyCode: "AUD"
    )

    let ckRecord = record.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "CD_InvestmentValueRecord")
    #expect(ckRecord["accountId"] as? String == accountId.uuidString)
    #expect(ckRecord["date"] as? Date == date)
    #expect(ckRecord["value"] as? Int == 250_000)
    #expect(ckRecord["currencyCode"] as? String == "AUD")

    let restored = InvestmentValueRecord.fieldValues(from: ckRecord)
    #expect(restored.id == record.id)
    #expect(restored.accountId == accountId)
    #expect(restored.date == date)
    #expect(restored.value == 250_000)
    #expect(restored.currencyCode == "AUD")
  }

  // MARK: - Record Type Strings

  @Test func recordTypeStrings() {
    #expect(ProfileRecord.recordType == "CD_ProfileRecord")
    #expect(AccountRecord.recordType == "CD_AccountRecord")
    #expect(TransactionRecord.recordType == "CD_TransactionRecord")
    #expect(CategoryRecord.recordType == "CD_CategoryRecord")
    #expect(EarmarkRecord.recordType == "CD_EarmarkRecord")
    #expect(EarmarkBudgetItemRecord.recordType == "CD_EarmarkBudgetItemRecord")
    #expect(InvestmentValueRecord.recordType == "CD_InvestmentValueRecord")
  }
}
