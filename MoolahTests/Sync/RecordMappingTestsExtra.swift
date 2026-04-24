import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("RecordMapping — Part 3")
struct RecordMappingTestsExtra {
  let zoneID = CKRecordZone.ID(zoneName: "profile-test", ownerName: CKCurrentUserDefaultName)

  @Test
  func transactionLegRecordNilOptionals() throws {
    let leg = TransactionLegRecord(
      transactionId: UUID(),
      accountId: UUID(),
      instrumentId: "AUD",
      quantity: 100_000_000,
      type: "expense"
    )

    let ckRecord = leg.toCKRecord(in: zoneID)
    #expect(ckRecord["categoryId"] == nil)
    #expect(ckRecord["earmarkId"] == nil)

    let restored = try #require(TransactionLegRecord.fieldValues(from: ckRecord))
    #expect(restored.categoryId == nil)
    #expect(restored.earmarkId == nil)
  }

  // MARK: - InstrumentRecord

  @Test
  func instrumentRecordRoundTrip() throws {
    let instrument = InstrumentRecord(
      id: "AUD",
      kind: "fiatCurrency",
      name: "Australian Dollar",
      decimals: 2
    )

    let ckRecord = instrument.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "CD_InstrumentRecord")
    #expect(ckRecord.recordID.recordName == "AUD")
    #expect(ckRecord["kind"] as? String == "fiatCurrency")
    #expect(ckRecord["name"] as? String == "Australian Dollar")
    #expect(ckRecord["decimals"] as? Int == 2)
    #expect(ckRecord["ticker"] == nil)
    #expect(ckRecord["exchange"] == nil)

    let restored = try #require(InstrumentRecord.fieldValues(from: ckRecord))
    #expect(restored.id == "AUD")
    #expect(restored.kind == "fiatCurrency")
    #expect(restored.name == "Australian Dollar")
    #expect(restored.decimals == 2)
    #expect(restored.ticker == nil)
    #expect(restored.exchange == nil)
  }

  @Test
  func instrumentRecordWithStockFields() throws {
    let instrument = InstrumentRecord(
      id: "ASX:BHP.AX",
      kind: "stock",
      name: "BHP Group",
      decimals: 2,
      ticker: "BHP.AX",
      exchange: "ASX"
    )

    let ckRecord = instrument.toCKRecord(in: zoneID)
    #expect(ckRecord["ticker"] as? String == "BHP.AX")
    #expect(ckRecord["exchange"] as? String == "ASX")

    let restored = try #require(InstrumentRecord.fieldValues(from: ckRecord))
    #expect(restored.ticker == "BHP.AX")
    #expect(restored.exchange == "ASX")
  }

  // MARK: - CategoryRecord

  @Test
  func categoryRecordRoundTrip() throws {
    let parentId = UUID()
    let category = CategoryRecord(id: UUID(), name: "Food", parentId: parentId)

    let ckRecord = category.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "CD_CategoryRecord")
    #expect(ckRecord["name"] as? String == "Food")
    #expect(ckRecord["parentId"] as? String == parentId.uuidString)

    let restored = try #require(CategoryRecord.fieldValues(from: ckRecord))
    #expect(restored.id == category.id)
    #expect(restored.name == "Food")
    #expect(restored.parentId == parentId)
  }

  @Test
  func categoryRecordNilParent() throws {
    let category = CategoryRecord(id: UUID(), name: "Root", parentId: nil)

    let ckRecord = category.toCKRecord(in: zoneID)
    #expect(ckRecord["parentId"] == nil)

    let restored = try #require(CategoryRecord.fieldValues(from: ckRecord))
    #expect(restored.parentId == nil)
  }

  // MARK: - EarmarkRecord

  @Test
  func earmarkRecordRoundTrip() throws {
    let startDate = Date(timeIntervalSince1970: 1_700_000_000)
    let endDate = Date(timeIntervalSince1970: 1_710_000_000)
    let earmark = EarmarkRecord(
      id: UUID(),
      name: "Holiday Fund",
      position: 3,
      isHidden: false,
      savingsTarget: 50_000_000_000,
      savingsTargetInstrumentId: "AUD",
      savingsStartDate: startDate,
      savingsEndDate: endDate
    )

    let ckRecord = earmark.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "CD_EarmarkRecord")
    #expect(ckRecord["name"] as? String == "Holiday Fund")
    #expect(ckRecord["position"] as? Int == 3)
    #expect(ckRecord["isHidden"] as? Int == 0)
    #expect(ckRecord["savingsTarget"] as? Int64 == 50_000_000_000)
    #expect(ckRecord["savingsTargetInstrumentId"] as? String == "AUD")
    #expect(ckRecord["savingsStartDate"] as? Date == startDate)
    #expect(ckRecord["savingsEndDate"] as? Date == endDate)

    let restored = try #require(EarmarkRecord.fieldValues(from: ckRecord))
    #expect(restored.id == earmark.id)
    #expect(restored.name == "Holiday Fund")
    #expect(restored.position == 3)
    #expect(restored.isHidden == false)
    #expect(restored.savingsTarget == 50_000_000_000)
    #expect(restored.savingsTargetInstrumentId == "AUD")
    #expect(restored.savingsStartDate == startDate)
    #expect(restored.savingsEndDate == endDate)
  }

  @Test
  func earmarkRecordNilOptionals() throws {
    let earmark = EarmarkRecord(
      id: UUID(),
      name: "Basic",
      position: 0,
      isHidden: false
    )

    let ckRecord = earmark.toCKRecord(in: zoneID)
    #expect(ckRecord["savingsTarget"] == nil)
    #expect(ckRecord["savingsTargetInstrumentId"] == nil)
    #expect(ckRecord["savingsStartDate"] == nil)
    #expect(ckRecord["savingsEndDate"] == nil)

    let restored = try #require(EarmarkRecord.fieldValues(from: ckRecord))
    #expect(restored.savingsTarget == nil)
    #expect(restored.savingsTargetInstrumentId == nil)
    #expect(restored.savingsStartDate == nil)
    #expect(restored.savingsEndDate == nil)
  }

  // MARK: - EarmarkBudgetItemRecord
}
