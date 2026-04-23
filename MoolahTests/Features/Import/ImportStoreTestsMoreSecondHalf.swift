import Foundation
import Testing

@testable import Moolah

@Suite("ImportStore")
@MainActor
struct ImportStoreTestsMoreSecondHalf {

  // MARK: - Fixtures + helpers

  private func tempStagingDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("import-store-\(UUID().uuidString)", isDirectory: true)
  }

  private func makeStore(
    backend: any BackendProvider,
    directory: URL? = nil
  ) throws -> (ImportStore, URL) {
    let dir = directory ?? tempStagingDirectory()
    let staging = try ImportStagingStore(directory: dir)
    return (ImportStore(backend: backend, staging: staging), dir)
  }

  private func seedAccount(
    _ backend: CloudKitBackend,
    id: UUID,
    name: String,
    instrument: Instrument = .AUD
  ) async throws {
    _ = try await backend.accounts.create(
      Account(
        id: id, name: name, type: .bank, instrument: instrument,
        positions: [], position: 0, isHidden: false),
      openingBalance: nil)
  }

  private func seedProfile(
    _ backend: CloudKitBackend,
    accountId: UUID,
    parser: String = "generic-bank",
    signature: [String] = ["date", "description", "debit", "credit", "balance"],
    deleteAfterImport: Bool = false,
    filenamePattern: String? = nil
  ) async throws -> CSVImportProfile {
    let profile = CSVImportProfile(
      accountId: accountId,
      parserIdentifier: parser,
      headerSignature: signature,
      filenamePattern: filenamePattern,
      deleteAfterImport: deleteAfterImport)
    return try await backend.csvImportProfiles.create(profile)
  }

  private func cbaFixtureBytes() throws -> Data {
    try CSVFixtureLoader.data("cba-everyday-standard")
  }

  @Test("every persisted transaction carries matching importOrigin")
  func importOriginStampedOnEveryPersisted() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    try await seedAccount(backend, id: accountId, name: "Cash")
    _ = try await seedProfile(backend, accountId: accountId)
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = try cbaFixtureBytes()
    let result = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))
    guard case .imported(let sessionId, let imported, _) = result else {
      Issue.record("expected .imported")
      return
    }
    #expect(imported.allSatisfy { $0.importOrigin?.importSessionId == sessionId })
    #expect(imported.allSatisfy { $0.importOrigin?.parserIdentifier == "generic-bank" })
    #expect(imported.allSatisfy { $0.importOrigin?.sourceFilename == "cba.csv" })
  }

  @Test("profile lastUsedAt is bumped after a successful routed import")
  func profileLastUsedAtBumped() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    try await seedAccount(backend, id: accountId, name: "Cash")
    _ = try await seedProfile(backend, accountId: accountId)
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let before = Date()
    let data = try cbaFixtureBytes()
    _ = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))
    let profiles = try await backend.csvImportProfiles.fetchAll()
    let lastUsedAt = profiles[0].lastUsedAt
    #expect(lastUsedAt != nil)
    if let lastUsedAt {
      #expect(lastUsedAt >= before)
    }
  }

  @Test("deleteAfterImport removes the source file after persistence")
  func deleteAfterImportRemovesSource() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    try await seedAccount(backend, id: accountId, name: "Cash")
    _ = try await seedProfile(
      backend, accountId: accountId, deleteAfterImport: true)
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("deleteable-\(UUID().uuidString).csv")
    try Data(try cbaFixtureBytes()).write(to: tmp)
    _ = await store.ingest(
      data: try Data(contentsOf: tmp),
      source: .pickedFile(url: tmp, securityScoped: false))
    #expect(FileManager.default.fileExists(atPath: tmp.path) == false)
  }

  @Test("SelfWealth fixture creates two-leg trade transactions end-to-end")
  func selfWealthFixtureCreatesTwoLegTrades() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    try await seedAccount(backend, id: accountId, name: "Brokerage")
    _ = try await seedProfile(
      backend,
      accountId: accountId,
      parser: "selfwealth",
      signature: ["date", "type", "description", "debit", "credit", "balance"])
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }

    let data = try CSVFixtureLoader.data("selfwealth-trades")
    let result = await store.ingest(
      data: data,
      source: .pickedFile(
        url: URL(fileURLWithPath: "/tmp/selfwealth.csv"), securityScoped: false))
    guard case .imported(_, let imported, _) = result else {
      Issue.record("expected .imported; got \(result)")
      return
    }

    // BHP buy: 2-leg transaction, cash AUD leg -4550.00, position ASX:BHP +100.
    let bhp = imported.first(where: {
      $0.importOrigin?.rawDescription.contains("BHP") == true
        && $0.legs.count == 2
    })
    #expect(bhp != nil)
    if let bhp {
      let cashLeg = bhp.legs.first(where: { $0.instrument == .AUD })
      #expect(cashLeg?.quantity == Decimal(string: "-4550.00"))
      #expect(cashLeg?.type == .expense)
      let positionLeg = bhp.legs.first(where: { $0.instrument.id == "ASX:BHP" })
      #expect(positionLeg?.quantity == 100)
      #expect(positionLeg?.type == .income)
      #expect(positionLeg?.instrument.kind == .stock)
    }

    // CBA sell: cash AUD +5512.50, position ASX:CBA -50.
    let cba = imported.first(where: {
      $0.importOrigin?.rawDescription.contains("CBA") == true
    })
    #expect(cba != nil)
    if let cba {
      let cashLeg = cba.legs.first(where: { $0.instrument == .AUD })
      #expect(cashLeg?.quantity == Decimal(string: "5512.50"))
      let positionLeg = cba.legs.first(where: { $0.instrument.id == "ASX:CBA" })
      #expect(positionLeg?.quantity == -50)
    }

    // Dividend is single-leg AUD income with SW-DIV-<ticker> bank reference.
    let dividend = imported.first(where: {
      $0.importOrigin?.rawDescription.contains("DIVIDEND") == true
    })
    #expect(dividend?.legs.count == 1)
    #expect(dividend?.importOrigin?.bankReference == "SW-DIV-BHP")
  }

  @Test("recentSessions carries one entry per successful ingest")
  func recentSessionsPopulated() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    try await seedAccount(backend, id: accountId, name: "Cash")
    _ = try await seedProfile(backend, accountId: accountId)
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = try cbaFixtureBytes()
    _ = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))
    _ = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))
    #expect(store.recentSessions.count == 2)
    // Newest-first ordering
    #expect(store.recentSessions[0].importedCount == 0)  // second run: all dup
    #expect(store.recentSessions[1].importedCount == 4)
  }
}
