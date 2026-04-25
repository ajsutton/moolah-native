import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("CloudKit record round trip")
struct RoundTripTests {

  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  @Test("AccountRecord round-trips through toCKRecord + fieldValues")
  func accountRoundTrip() throws {
    let original = AccountRecord(
      id: UUID(),
      name: "Sample",
      type: "bank",
      instrumentId: "AUD",
      position: 7,
      isHidden: true
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(AccountRecord.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(decoded.name == original.name)
    #expect(decoded.type == original.type)
    #expect(decoded.instrumentId == original.instrumentId)
    #expect(decoded.position == original.position)
    #expect(decoded.isHidden == original.isHidden)
  }

  @Test("ProfileRecord round-trips through toCKRecord + fieldValues")
  func profileRoundTrip() throws {
    let original = ProfileRecord(
      id: UUID(),
      label: "Personal",
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      createdAt: Date()
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(ProfileRecord.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(decoded.label == original.label)
    #expect(decoded.currencyCode == original.currencyCode)
    #expect(decoded.financialYearStartMonth == original.financialYearStartMonth)
    #expect(abs(decoded.createdAt.timeIntervalSince(original.createdAt)) < 1)
  }

  @Test("CategoryRecord round-trips with parentId set")
  func categoryRoundTripWithParent() throws {
    let original = CategoryRecord(
      id: UUID(),
      name: "Groceries",
      parentId: UUID()
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(CategoryRecord.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(decoded.name == original.name)
    #expect(decoded.parentId == original.parentId)
  }

  @Test("CategoryRecord round-trips with parentId nil")
  func categoryRoundTripNoParent() throws {
    let original = CategoryRecord(id: UUID(), name: "Top", parentId: nil)
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(CategoryRecord.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(decoded.name == original.name)
    #expect(decoded.parentId == nil)
  }

  @Test("EarmarkBudgetItemRecord round-trips")
  func earmarkBudgetItemRoundTrip() throws {
    let original = EarmarkBudgetItemRecord(
      id: UUID(),
      earmarkId: UUID(),
      categoryId: UUID(),
      amount: 1234,
      instrumentId: "AUD"
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(EarmarkBudgetItemRecord.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(decoded.earmarkId == original.earmarkId)
    #expect(decoded.categoryId == original.categoryId)
    #expect(decoded.amount == original.amount)
    #expect(decoded.instrumentId == original.instrumentId)
  }
}
