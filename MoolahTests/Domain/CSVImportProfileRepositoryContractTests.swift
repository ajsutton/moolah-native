import Foundation
import Testing

@testable import Moolah

@Suite("CSVImportProfileRepository Contract")
struct CSVImportProfileRepositoryContractTests {

  @Test("create, fetchAll, update, delete round-trip")
  func lifecycle() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    _ = try await backend.accounts.create(
      Account(
        id: accountId, name: "Cash", type: .bank, instrument: .AUD,
        positions: [], position: 0, isHidden: false), openingBalance: nil)
    let profile = CSVImportProfile(
      accountId: accountId,
      parserIdentifier: "generic-bank",
      headerSignature: ["date", "amount", "description", "balance"])

    _ = try await backend.csvImportProfiles.create(profile)
    var all = try await backend.csvImportProfiles.fetchAll()
    #expect(all.count == 1)
    #expect(all[0].id == profile.id)
    #expect(all[0].parserIdentifier == "generic-bank")
    #expect(all[0].headerSignature == ["date", "amount", "description", "balance"])

    var updated = profile
    updated.filenamePattern = "cba-*.csv"
    updated.deleteAfterImport = true
    updated.lastUsedAt = Date(timeIntervalSince1970: 1_700_000_000)
    _ = try await backend.csvImportProfiles.update(updated)
    all = try await backend.csvImportProfiles.fetchAll()
    #expect(all[0].filenamePattern == "cba-*.csv")
    #expect(all[0].deleteAfterImport == true)
    #expect(all[0].lastUsedAt == Date(timeIntervalSince1970: 1_700_000_000))

    try await backend.csvImportProfiles.delete(id: profile.id)
    all = try await backend.csvImportProfiles.fetchAll()
    #expect(all.isEmpty)
  }

  @Test("headerSignature is stored in normalised (lowercased/trimmed) form")
  func headerSignatureNormalisation() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    _ = try await backend.accounts.create(
      Account(
        id: accountId, name: "Cash", type: .bank, instrument: .AUD,
        positions: [], position: 0, isHidden: false), openingBalance: nil)
    let profile = CSVImportProfile(
      accountId: accountId,
      parserIdentifier: "generic-bank",
      headerSignature: ["  Date ", "AMOUNT", "description"])
    _ = try await backend.csvImportProfiles.create(profile)
    let fetched = try await backend.csvImportProfiles.fetchAll()
    #expect(fetched[0].headerSignature == ["date", "amount", "description"])
  }

  @Test("delete of non-existent id throws")
  func deleteMissingThrows() async throws {
    let (backend, _) = try TestBackend.create()
    await #expect(throws: BackendError.self) {
      try await backend.csvImportProfiles.delete(id: UUID())
    }
  }
}
