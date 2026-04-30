import CloudKit
import Foundation
import Testing

@testable import Moolah

/// Verifies the CloudKit wire-format round-trip for every
/// `CloudKitRecordConvertible` row + the surviving `ProfileRecord`. Each
/// `toCKRecord(in:)` write must be losslessly recoverable through
/// `fieldValues(from:)` so a remote pull rebuilds the local row with the
/// same field values it produced. Wire `recordType` strings are pinned to
/// their string-literal CloudKit identifiers because existing iCloud
/// zones reference those exact names regardless of any local Swift type
/// rename.
@Suite("RecordMapping")
struct RecordMappingTests {

  let zoneID = CKRecordZone.ID(zoneName: "profile-test", ownerName: CKCurrentUserDefaultName)

  // MARK: - ProfileRecord (still owned by the SwiftData layer)

  @Test
  func profileRecordRoundTrip() throws {
    let profile = ProfileRecord(
      id: UUID(),
      label: "My Budget",
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let ckRecord = profile.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "ProfileRecord")
    #expect(
      ckRecord.recordID.recordName
        == "\(ProfileRecord.recordType)|\(profile.id.uuidString)")
    #expect(ckRecord.recordID.zoneID == zoneID)
    #expect(ckRecord["label"] as? String == "My Budget")
    #expect(ckRecord["currencyCode"] as? String == "AUD")
    #expect(ckRecord["financialYearStartMonth"] as? Int == 7)
    #expect(ckRecord["createdAt"] as? Date == profile.createdAt)

    let restored = try #require(ProfileRecord.fieldValues(from: ckRecord))
    #expect(restored.id == profile.id)
    #expect(restored.label == "My Budget")
    #expect(restored.currencyCode == "AUD")
    #expect(restored.financialYearStartMonth == 7)
    #expect(restored.createdAt == profile.createdAt)
  }

  // MARK: - AccountRow

  @Test
  func accountRowRoundTrip() throws {
    let row = AccountRow(
      id: UUID(),
      recordName: "",
      name: "Savings",
      type: "bank",
      instrumentId: "USD",
      position: 2,
      isHidden: true,
      encodedSystemFields: nil
    )

    let ckRecord = row.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "AccountRecord")
    #expect(
      ckRecord.recordID.recordName
        == "\(AccountRow.recordType)|\(row.id.uuidString)")
    #expect(ckRecord["name"] as? String == "Savings")
    #expect(ckRecord["type"] as? String == "bank")
    #expect(ckRecord["instrumentId"] as? String == "USD")
    #expect(ckRecord["position"] as? Int == 2)
    #expect(ckRecord["isHidden"] as? Int == 1)

    let restored = try #require(AccountRow.fieldValues(from: ckRecord))
    #expect(restored.id == row.id)
    #expect(restored.name == "Savings")
    #expect(restored.type == "bank")
    #expect(restored.instrumentId == "USD")
    #expect(restored.position == 2)
    #expect(restored.isHidden == true)
  }

  @Test
  func accountRowFieldValuesDefaultsInstrumentId() throws {
    // When instrumentId is missing from CKRecord, default to "AUD"
    let recordID = CKRecord.ID(
      recordType: AccountRow.recordType, uuid: UUID(), zoneID: zoneID)
    let ckRecord = CKRecord(recordType: "AccountRecord", recordID: recordID)
    ckRecord["name"] = "Test" as CKRecordValue
    ckRecord["type"] = "bank" as CKRecordValue
    // No instrumentId set

    let restored = try #require(AccountRow.fieldValues(from: ckRecord))
    #expect(restored.instrumentId == "AUD")
  }

  // MARK: - TransactionRow

  @Test
  func transactionRowRoundTrip() throws {
    let txnDate = Date(timeIntervalSince1970: 1_700_000_000)
    let id = UUID()
    let row = TransactionRow(
      id: id,
      recordName: TransactionRow.recordName(for: id),
      date: txnDate,
      payee: "Rent",
      notes: "Monthly rent",
      recurPeriod: "monthly",
      recurEvery: 1,
      importOriginRawDescription: nil,
      importOriginBankReference: nil,
      importOriginRawAmount: nil,
      importOriginRawBalance: nil,
      importOriginImportedAt: nil,
      importOriginImportSessionId: nil,
      importOriginSourceFilename: nil,
      importOriginParserIdentifier: nil,
      encodedSystemFields: nil)

    let ckRecord = row.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "TransactionRecord")
    #expect(
      ckRecord.recordID.recordName
        == "\(TransactionRow.recordType)|\(row.id.uuidString)")
    #expect(ckRecord["date"] as? Date == txnDate)
    #expect(ckRecord["payee"] as? String == "Rent")
    #expect(ckRecord["notes"] as? String == "Monthly rent")
    #expect(ckRecord["recurPeriod"] as? String == "monthly")
    #expect(ckRecord["recurEvery"] as? Int == 1)

    let restored = try #require(TransactionRow.fieldValues(from: ckRecord))
    #expect(restored.id == row.id)
    #expect(restored.date == txnDate)
    #expect(restored.payee == "Rent")
    #expect(restored.notes == "Monthly rent")
    #expect(restored.recurPeriod == "monthly")
    #expect(restored.recurEvery == 1)
  }

  @Test
  func transactionRowNilOptionals() throws {
    let id = UUID()
    let row = TransactionRow(
      id: id,
      recordName: TransactionRow.recordName(for: id),
      date: Date(),
      payee: nil,
      notes: nil,
      recurPeriod: nil,
      recurEvery: nil,
      importOriginRawDescription: nil,
      importOriginBankReference: nil,
      importOriginRawAmount: nil,
      importOriginRawBalance: nil,
      importOriginImportedAt: nil,
      importOriginImportSessionId: nil,
      importOriginSourceFilename: nil,
      importOriginParserIdentifier: nil,
      encodedSystemFields: nil)

    let ckRecord = row.toCKRecord(in: zoneID)
    #expect(ckRecord["payee"] == nil)
    #expect(ckRecord["notes"] == nil)
    #expect(ckRecord["recurPeriod"] == nil)
    #expect(ckRecord["recurEvery"] == nil)

    let restored = try #require(TransactionRow.fieldValues(from: ckRecord))
    #expect(restored.payee == nil)
    #expect(restored.notes == nil)
    #expect(restored.recurPeriod == nil)
    #expect(restored.recurEvery == nil)
  }

  // MARK: - TransactionLegRow

  @Test
  func transactionLegRowRoundTrip() throws {
    let transactionId = UUID()
    let accountId = UUID()
    let categoryId = UUID()
    let earmarkId = UUID()
    let legId = UUID()

    let row = TransactionLegRow(
      id: legId,
      recordName: TransactionLegRow.recordName(for: legId),
      transactionId: transactionId,
      accountId: accountId,
      instrumentId: "AUD",
      quantity: 500_000_000,
      type: "expense",
      categoryId: categoryId,
      earmarkId: earmarkId,
      sortOrder: 0,
      encodedSystemFields: nil)

    let ckRecord = row.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "TransactionLegRecord")
    #expect(
      ckRecord.recordID.recordName
        == "\(TransactionLegRow.recordType)|\(row.id.uuidString)")
    #expect(ckRecord["transactionId"] as? String == transactionId.uuidString)
    #expect(ckRecord["accountId"] as? String == accountId.uuidString)
    #expect(ckRecord["instrumentId"] as? String == "AUD")
    #expect(ckRecord["quantity"] as? Int64 == 500_000_000)
    #expect(ckRecord["type"] as? String == "expense")
    #expect(ckRecord["categoryId"] as? String == categoryId.uuidString)
    #expect(ckRecord["earmarkId"] as? String == earmarkId.uuidString)
    #expect(ckRecord["sortOrder"] as? Int == 0)

    let restored = try #require(TransactionLegRow.fieldValues(from: ckRecord))
    #expect(restored.id == row.id)
    #expect(restored.transactionId == transactionId)
    #expect(restored.accountId == accountId)
    #expect(restored.instrumentId == "AUD")
    #expect(restored.quantity == 500_000_000)
    #expect(restored.type == "expense")
    #expect(restored.categoryId == categoryId)
    #expect(restored.earmarkId == earmarkId)
    #expect(restored.sortOrder == 0)
  }

  // MARK: - Malformed recordID propagation

  /// UUID-keyed conformers must return `nil` from `fieldValues(from:)` when the
  /// incoming `CKRecord` has a non-UUID `recordName`, so a phantom row with a
  /// freshly-minted UUID is never silently inserted.
  @Test
  func uuidKeyedRecordsReturnNilForNonUUIDRecordName() {
    let malformedID = CKRecord.ID(recordName: "not-a-uuid", zoneID: zoneID)

    let accountRecord = CKRecord(recordType: AccountRow.recordType, recordID: malformedID)
    #expect(AccountRow.fieldValues(from: accountRecord) == nil)

    let txnRecord = CKRecord(recordType: TransactionRow.recordType, recordID: malformedID)
    #expect(TransactionRow.fieldValues(from: txnRecord) == nil)

    let legRecord = CKRecord(recordType: TransactionLegRow.recordType, recordID: malformedID)
    #expect(TransactionLegRow.fieldValues(from: legRecord) == nil)

    let categoryRecord = CKRecord(recordType: CategoryRow.recordType, recordID: malformedID)
    #expect(CategoryRow.fieldValues(from: categoryRecord) == nil)

    let earmarkRecord = CKRecord(recordType: EarmarkRow.recordType, recordID: malformedID)
    #expect(EarmarkRow.fieldValues(from: earmarkRecord) == nil)

    let budgetItemRecord = CKRecord(
      recordType: EarmarkBudgetItemRow.recordType, recordID: malformedID)
    #expect(EarmarkBudgetItemRow.fieldValues(from: budgetItemRecord) == nil)

    let investmentRecord = CKRecord(
      recordType: InvestmentValueRow.recordType, recordID: malformedID)
    #expect(InvestmentValueRow.fieldValues(from: investmentRecord) == nil)

    let profileRecord = CKRecord(recordType: ProfileRecord.recordType, recordID: malformedID)
    #expect(ProfileRecord.fieldValues(from: profileRecord) == nil)

    // ProfileRow shares the wire `recordType` with `ProfileRecord` but is a
    // distinct local type; until `RecordTypeRegistry` flips its mapping
    // there is no registry entry covering it, so assert the malformed
    // guard explicitly.
    let profileRowRecord = CKRecord(recordType: ProfileRow.recordType, recordID: malformedID)
    #expect(ProfileRow.fieldValues(from: profileRowRecord) == nil)

    let csvProfileRecord = CKRecord(
      recordType: CSVImportProfileRow.recordType, recordID: malformedID)
    #expect(CSVImportProfileRow.fieldValues(from: csvProfileRecord) == nil)

    let ruleRecord = CKRecord(recordType: ImportRuleRow.recordType, recordID: malformedID)
    #expect(ImportRuleRow.fieldValues(from: ruleRecord) == nil)
  }

  /// `InstrumentRow` is keyed by `recordName` rather than `uuid`, so any
  /// non-empty record name is valid. The Optional return keeps the
  /// protocol uniform, but successful decoding always yields a non-nil
  /// value.
  @Test
  func instrumentRowIsNotSubjectToUUIDNilPropagation() throws {
    let recordID = CKRecord.ID(recordName: "AUD", zoneID: zoneID)
    let ckRecord = CKRecord(recordType: InstrumentRow.recordType, recordID: recordID)
    ckRecord["kind"] = "fiatCurrency" as CKRecordValue
    ckRecord["name"] = "Australian Dollar" as CKRecordValue
    ckRecord["decimals"] = 2 as CKRecordValue

    let restored = try #require(InstrumentRow.fieldValues(from: ckRecord))
    #expect(restored.id == "AUD")
  }
}

/// Wire-format round-trip + boundary coverage for the GRDB `ProfileRow`
/// `CloudKitRecordConvertible` conformance. Lives in its own suite so
/// `RecordMappingTests`'s body stays under SwiftLint's
/// `type_body_length` threshold; it would be a natural sibling section
/// otherwise.
@Suite("ProfileRowMapping")
struct ProfileRowMappingTests {

  let zoneID = CKRecordZone.ID(zoneName: "profile-test", ownerName: CKCurrentUserDefaultName)

  @Test
  func profileRowRoundTrip() throws {
    let id = UUID()
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let row = ProfileRow(
      id: id,
      recordName: ProfileRow.recordName(for: id),
      label: "Household",
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      createdAt: createdAt,
      encodedSystemFields: nil)

    let ckRecord = row.toCKRecord(in: zoneID)

    #expect(ckRecord.recordType == "ProfileRecord")
    #expect(
      ckRecord.recordID.recordName
        == ProfileRow.recordName(for: id))
    #expect(ckRecord.recordID.zoneID == zoneID)
    #expect(ckRecord["label"] as? String == "Household")
    #expect(ckRecord["currencyCode"] as? String == "AUD")
    #expect(ckRecord["financialYearStartMonth"] as? Int == 7)
    #expect(ckRecord["createdAt"] as? Date == createdAt)

    let restored = try #require(ProfileRow.fieldValues(from: ckRecord))
    #expect(restored.id == id)
    #expect(restored.recordName == ProfileRow.recordName(for: id))
    #expect(restored.label == "Household")
    #expect(restored.currencyCode == "AUD")
    #expect(restored.financialYearStartMonth == 7)
    #expect(restored.createdAt == createdAt)
    #expect(restored.encodedSystemFields == nil)
  }

  @Test
  func profileRowCoercesOutOfRangeMonth() throws {
    let id = UUID()
    let recordID = CKRecord.ID(
      recordType: ProfileRow.recordType, uuid: id, zoneID: zoneID)
    let ckRecord = CKRecord(recordType: "ProfileRecord", recordID: recordID)
    ckRecord["label"] = "Out of range" as CKRecordValue
    ckRecord["currencyCode"] = "AUD" as CKRecordValue
    ckRecord["financialYearStartMonth"] = 13 as CKRecordValue
    ckRecord["createdAt"] = Date(timeIntervalSince1970: 1_700_000_000) as CKRecordValue

    let restored = try #require(ProfileRow.fieldValues(from: ckRecord))
    #expect(restored.financialYearStartMonth == 7)
  }

  @Test
  func profileRowDefaultsMonthWhenAbsent() throws {
    let id = UUID()
    let recordID = CKRecord.ID(
      recordType: ProfileRow.recordType, uuid: id, zoneID: zoneID)
    let ckRecord = CKRecord(recordType: "ProfileRecord", recordID: recordID)
    ckRecord["label"] = "No month" as CKRecordValue
    ckRecord["currencyCode"] = "AUD" as CKRecordValue
    // No financialYearStartMonth set

    let restored = try #require(ProfileRow.fieldValues(from: ckRecord))
    #expect(restored.financialYearStartMonth == 7)
  }
}
