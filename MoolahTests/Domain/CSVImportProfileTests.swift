import Foundation
import Testing

@testable import Moolah

@Suite("CSVImportProfile")
struct CSVImportProfileTests {

  @Test("CSVImportProfile round-trips via Codable")
  func codableRoundTrip() throws {
    let profile = CSVImportProfile(
      id: UUID(),
      accountId: UUID(),
      parserIdentifier: "generic-bank",
      headerSignature: ["date", "amount", "description", "balance"],
      filenamePattern: "cba-*.csv",
      deleteAfterImport: false,
      createdAt: Date(timeIntervalSince1970: 0),
      lastUsedAt: nil)
    let data = try JSONEncoder().encode(profile)
    let decoded = try JSONDecoder().decode(CSVImportProfile.self, from: data)
    #expect(decoded == profile)
  }

  @Test("headerSignature is normalised (trimmed + lowercased) on init")
  func headerSignatureNormalisation() {
    let profile = CSVImportProfile(
      accountId: UUID(),
      parserIdentifier: "generic-bank",
      headerSignature: ["  Date ", "AMOUNT", "Description"])
    #expect(profile.headerSignature == ["date", "amount", "description"])
  }

  @Test("normalise(_:) trims and lowercases")
  func normaliseHelper() {
    #expect(CSVImportProfile.normalise("  Date  ") == "date")
    #expect(CSVImportProfile.normalise("Amount (AUD)") == "amount (aud)")
    #expect(CSVImportProfile.normalise("").isEmpty)
  }
}
