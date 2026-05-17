import CloudKit
import Foundation
import Testing

@testable import Moolah

/// Pins the eleven transfer-detection wire keys on the
/// `"TransactionRecord"` CKRecord: `importOriginKind`, the eight
/// `importOriginIncoming*` columns, and the two `transferSuggestion*`
/// columns. These string keys are a frozen CloudKit contract — existing
/// iCloud zones reference these exact names — so the round-trip is
/// asserted by string key, not just by decoded value. A separate suite
/// (and file) from `RecordMappingTests` keeps each within its length
/// budget.
@Suite("TransferWireKeyMapping")
struct TransferWireKeyMappingTests {

  let zoneID = CKRecordZone.ID(zoneName: "profile-test", ownerName: CKCurrentUserDefaultName)

  private let importedAt = Date(timeIntervalSince1970: 1_700_000_100)
  private let suggestedAt = Date(timeIntervalSince1970: 1_700_000_200)
  private let txnDate = Date(timeIntervalSince1970: 1_700_000_000)

  /// Builds a `.merged` transaction whose outgoing/incoming origins and
  /// `TransferSuggestion` populate all eleven new columns.
  private func makeMergedTransaction(
    outgoingSessionId: UUID,
    incomingSessionId: UUID,
    counterpartId: UUID
  ) -> Transaction {
    let outgoing = ImportOrigin(
      rawDescription: "OUT debit raw",
      bankReference: "OUTREF",
      rawAmount: Decimal(-12_345) / 100,
      rawBalance: Decimal(100_000) / 100,
      importedAt: importedAt,
      importSessionId: outgoingSessionId,
      sourceFilename: "out.csv",
      parserIdentifier: "csv-parser-out")
    let incoming = ImportOrigin(
      rawDescription: "IN credit raw",
      bankReference: "INREF",
      rawAmount: Decimal(12_345) / 100,
      rawBalance: Decimal(212_345) / 100,
      importedAt: importedAt,
      importSessionId: incomingSessionId,
      sourceFilename: "in.csv",
      parserIdentifier: "csv-parser-in")
    let leg = TransactionLeg(
      accountId: UUID(),
      instrument: Instrument.USD,
      quantity: Decimal(-12_345) / 100,
      type: .transfer)
    return Transaction(
      date: txnDate,
      payee: "Merged transfer",
      legs: [leg],
      importOrigin: .merged(MergedImportOrigin(outgoing: outgoing, incoming: incoming)),
      transferSuggestion: TransferSuggestion(
        counterpartTransactionId: counterpartId, suggestedAt: suggestedAt))
  }

  @Test("merged + suggestion wire keys round-trip by string key")
  func mergedAndSuggestionWireKeysRoundTrip() throws {
    let outgoingSessionId = UUID()
    let incomingSessionId = UUID()
    let counterpartId = UUID()
    let transaction = makeMergedTransaction(
      outgoingSessionId: outgoingSessionId,
      incomingSessionId: incomingSessionId,
      counterpartId: counterpartId)

    let ckRecord = TransactionRow(domain: transaction).toCKRecord(in: zoneID)

    #expect(ckRecord["importOriginKind"] as? String == "merged")
    #expect(
      ckRecord["transferSuggestionCounterpartId"] as? String
        == counterpartId.uuidString)
    #expect(ckRecord["transferSuggestionSuggestedAt"] as? Date == suggestedAt)
    #expect(
      ckRecord["importOriginIncomingRawDescription"] as? String
        == "IN credit raw")
    #expect(
      ckRecord["importOriginIncomingImportSessionId"] as? String
        == incomingSessionId.uuidString)

    let restored = try #require(TransactionRow.fieldValues(from: ckRecord))
    #expect(restored.importOriginKind == "merged")
    #expect(restored.importOriginIncomingRawDescription == "IN credit raw")
    #expect(restored.importOriginIncomingBankReference == "INREF")
    #expect(restored.importOriginIncomingImportSessionId == incomingSessionId)
    #expect(restored.importOriginIncomingSourceFilename == "in.csv")
    #expect(restored.importOriginIncomingParserIdentifier == "csv-parser-in")
    #expect(restored.transferSuggestionCounterpartId == counterpartId)
    #expect(restored.transferSuggestionSuggestedAt == suggestedAt)
  }

  @Test("plain transaction skips the new transfer wire keys")
  func plainTransactionSkipsNewWireKeys() {
    let leg = TransactionLeg(
      accountId: UUID(),
      instrument: Instrument.USD,
      quantity: Decimal(5_000) / 100,
      type: .expense)
    let plain = Transaction(date: txnDate, payee: "Plain", legs: [leg])

    let ckRecord = TransactionRow(domain: plain).toCKRecord(in: zoneID)

    #expect(ckRecord["importOriginKind"] == nil)
    #expect(ckRecord["transferSuggestionCounterpartId"] == nil)
    #expect(ckRecord["importOriginIncomingRawDescription"] == nil)
  }
}
