import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("CloudKit record round trip — import adapters")
@MainActor
struct RoundTripImportTests {

  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  @Test("ImportRuleRecord round-trips with BYTES and UUID-string fields")
  func importRuleRoundTrip() throws {
    let conditionsJSON = Data(#"[{"field":"payee"}]"#.utf8)
    let actionsJSON = Data(#"[{"set":"category"}]"#.utf8)
    let original = ImportRuleRecord(
      id: UUID(),
      name: "Rent",
      enabled: true,
      position: 0,
      matchMode: .all,
      conditions: [],
      actions: [],
      accountScope: UUID()
    )
    original.conditionsJSON = conditionsJSON
    original.actionsJSON = actionsJSON

    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(ImportRuleRecord.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(decoded.name == original.name)
    #expect(decoded.enabled == original.enabled)
    #expect(decoded.position == original.position)
    #expect(decoded.matchMode == original.matchMode)
    #expect(decoded.accountScope == original.accountScope)
    #expect(decoded.conditionsJSON == conditionsJSON)
    #expect(decoded.actionsJSON == actionsJSON)
  }

  @Test("CSVImportProfileRecord round-trips")
  func csvImportProfileRoundTrip() throws {
    let original = CSVImportProfileRecord(
      id: UUID(),
      accountId: UUID(),
      parserIdentifier: "generic",
      headerSignature: ["a", "b", "c"],
      filenamePattern: "statement-*.csv",
      deleteAfterImport: true,
      createdAt: Date(),
      lastUsedAt: Date(),
      dateFormatRawValue: "yyyy-MM-dd",
      columnRoleRawValuesEncoded: "amount\u{1F}date\u{1F}description"
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(CSVImportProfileRecord.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(decoded.accountId == original.accountId)
    #expect(decoded.parserIdentifier == original.parserIdentifier)
    #expect(decoded.headerSignature == original.headerSignature)
    #expect(decoded.filenamePattern == original.filenamePattern)
    #expect(decoded.deleteAfterImport == original.deleteAfterImport)
    #expect(decoded.dateFormatRawValue == original.dateFormatRawValue)
    #expect(decoded.columnRoleRawValuesEncoded == original.columnRoleRawValuesEncoded)
  }
}
