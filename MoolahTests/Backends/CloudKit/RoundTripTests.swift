import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("CloudKit record round trip")
@MainActor
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

  @Test("EarmarkRecord round-trips with all optionals set")
  func earmarkRoundTripFull() throws {
    let original = EarmarkRecord(
      id: UUID(),
      name: "Holiday",
      position: 0,
      isHidden: false,
      instrumentId: "AUD",
      savingsTarget: 5_000_00,
      savingsTargetInstrumentId: "AUD",
      savingsStartDate: Date(),
      savingsEndDate: Date()
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(EarmarkRecord.fieldValues(from: record))
    #expect(decoded.name == original.name)
    #expect(decoded.position == original.position)
    #expect(decoded.isHidden == original.isHidden)
    #expect(decoded.instrumentId == original.instrumentId)
    #expect(decoded.savingsTarget == original.savingsTarget)
    #expect(decoded.savingsTargetInstrumentId == original.savingsTargetInstrumentId)
  }

  @Test("EarmarkRecord round-trips with all optionals nil")
  func earmarkRoundTripMinimal() throws {
    let original = EarmarkRecord(
      id: UUID(),
      name: "Empty",
      position: 0,
      isHidden: false,
      instrumentId: nil,
      savingsTarget: nil,
      savingsTargetInstrumentId: nil,
      savingsStartDate: nil,
      savingsEndDate: nil
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(EarmarkRecord.fieldValues(from: record))
    #expect(decoded.savingsTarget == nil)
    #expect(decoded.instrumentId == nil)
  }

  @Test("TransactionLegRecord round-trips")
  func transactionLegRoundTrip() throws {
    let original = TransactionLegRecord(
      id: UUID(),
      transactionId: UUID(),
      accountId: UUID(),
      instrumentId: "AUD",
      quantity: -100,
      type: "expense",
      categoryId: UUID(),
      earmarkId: UUID(),
      sortOrder: 0
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(TransactionLegRecord.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(decoded.transactionId == original.transactionId)
    #expect(decoded.accountId == original.accountId)
    #expect(decoded.quantity == original.quantity)
    #expect(decoded.type == original.type)
    #expect(decoded.categoryId == original.categoryId)
    #expect(decoded.earmarkId == original.earmarkId)
  }

  @Test("TransactionLegRecord round-trips with all optional fields nil")
  func transactionLegRoundTripWithNilOptionals() throws {
    let original = TransactionLegRecord(
      id: UUID(),
      transactionId: UUID(),
      accountId: nil,
      instrumentId: "AUD",
      quantity: -100,
      type: "expense",
      categoryId: nil,
      earmarkId: nil,
      sortOrder: 0
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(TransactionLegRecord.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(decoded.transactionId == original.transactionId)
    #expect(decoded.accountId == nil)
    #expect(decoded.categoryId == nil)
    #expect(decoded.earmarkId == nil)
  }

  @Test("InvestmentValueRecord round-trips")
  func investmentValueRoundTrip() throws {
    let original = InvestmentValueRecord(
      id: UUID(),
      accountId: UUID(),
      date: Date(),
      value: 12345,
      instrumentId: "ASX:BHP"
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(InvestmentValueRecord.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(decoded.accountId == original.accountId)
    #expect(decoded.value == original.value)
    #expect(decoded.instrumentId == original.instrumentId)
  }

  @Test("TransactionRecord round-trips with all import-origin fields populated")
  func transactionRoundTripFull() throws {
    let original = TransactionRecord(
      id: UUID(),
      date: Date(),
      payee: "Coles",
      notes: "weekly shop",
      recurPeriod: "month",
      recurEvery: 1
    )
    original.importOriginRawDescription = "COLES 1234"
    original.importOriginBankReference = "REF-1"
    original.importOriginRawAmount = "-100.00"
    original.importOriginRawBalance = "1000.00"
    original.importOriginImportedAt = Date()
    original.importOriginImportSessionId = UUID()
    original.importOriginSourceFilename = "statement.csv"
    original.importOriginParserIdentifier = "generic"

    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(TransactionRecord.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(abs(decoded.date.timeIntervalSince(original.date)) < 1)
    #expect(decoded.payee == original.payee)
    #expect(decoded.notes == original.notes)
    #expect(decoded.recurPeriod == original.recurPeriod)
    #expect(decoded.recurEvery == original.recurEvery)
    #expect(decoded.importOriginRawDescription == original.importOriginRawDescription)
    #expect(decoded.importOriginBankReference == original.importOriginBankReference)
    #expect(decoded.importOriginImportSessionId == original.importOriginImportSessionId)
    #expect(decoded.importOriginParserIdentifier == original.importOriginParserIdentifier)
  }

  @Test("TransactionRecord round-trips with no import-origin fields")
  func transactionRoundTripMinimal() throws {
    let original = TransactionRecord(
      id: UUID(),
      date: Date(),
      payee: nil,
      notes: nil,
      recurPeriod: nil,
      recurEvery: nil
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(TransactionRecord.fieldValues(from: record))
    #expect(abs(decoded.date.timeIntervalSince(original.date)) < 1)
    #expect(decoded.payee == nil)
    #expect(decoded.importOriginRawDescription == nil)
  }

}
