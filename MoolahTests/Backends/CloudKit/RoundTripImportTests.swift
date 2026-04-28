import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("CloudKit record round trip — import adapters")
@MainActor
struct RoundTripImportTests {

  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  @Test("ImportRuleRow round-trips with BYTES and UUID-string fields")
  func importRuleRoundTrip() throws {
    let conditionsJSON = Data(#"[{"field":"payee"}]"#.utf8)
    let actionsJSON = Data(#"[{"set":"category"}]"#.utf8)
    let id = UUID()
    let original = ImportRuleRow(
      id: id,
      recordName: ImportRuleRow.recordName(for: id),
      name: "Rent",
      enabled: true,
      position: 0,
      matchMode: MatchMode.all.rawValue,
      conditionsJSON: conditionsJSON,
      actionsJSON: actionsJSON,
      accountScope: UUID(),
      encodedSystemFields: nil
    )

    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(ImportRuleRow.fieldValues(from: record))
    #expect(decoded.id == original.id)
    #expect(decoded.name == original.name)
    #expect(decoded.enabled == original.enabled)
    #expect(decoded.position == original.position)
    #expect(decoded.matchMode == original.matchMode)
    #expect(decoded.accountScope == original.accountScope)
    #expect(decoded.conditionsJSON == conditionsJSON)
    #expect(decoded.actionsJSON == actionsJSON)
  }

  @Test("CSVImportProfileRow round-trips")
  func csvImportProfileRoundTrip() throws {
    let id = UUID()
    let original = CSVImportProfileRow(
      id: id,
      recordName: CSVImportProfileRow.recordName(for: id),
      accountId: UUID(),
      parserIdentifier: "generic",
      headerSignature: ["a", "b", "c"].joined(separator: CSVImportProfileRow.separator),
      filenamePattern: "statement-*.csv",
      deleteAfterImport: true,
      createdAt: Date(),
      lastUsedAt: Date(),
      dateFormatRawValue: "yyyy-MM-dd",
      columnRoleRawValuesEncoded: "amount\u{1F}date\u{1F}description",
      encodedSystemFields: nil
    )
    let record = original.toCKRecord(in: Self.zoneID)
    let decoded = try #require(CSVImportProfileRow.fieldValues(from: record))
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
