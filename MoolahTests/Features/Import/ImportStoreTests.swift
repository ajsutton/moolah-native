import Foundation
import Testing

@testable import Moolah

@Suite("ImportStore")
@MainActor
struct ImportStoreTests {

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

  // MARK: - Routing

  @Test("first-time ingest with no profile lands in Needs Setup")
  func firstTimeIngestNeedsSetup() async throws {
    let (backend, _) = try TestBackend.create()
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = try cbaFixtureBytes()
    let result = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))
    if case .needsSetup(let id) = result {
      #expect(store.pendingSetup.count == 1)
      #expect(store.pendingSetup[0].id == id)
    } else {
      Issue.record("expected .needsSetup; got \(result)")
    }
  }

  @Test("routed silently when profile matches — all rows persisted")
  func routedSilentlyAllRowsPersisted() async throws {
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

    if case .imported(_, let imported, let skipped) = result {
      // CBA fixture has 5 data rows; row 1 is opening balance (.skip from parser),
      // so 4 real transactions land.
      #expect(imported.count == 4)
      #expect(skipped == 0)
      let page = try await backend.transactions.fetch(
        filter: TransactionFilter(accountId: accountId), page: 0, pageSize: 50)
      #expect(page.transactions.count == 4)
    } else {
      Issue.record("expected .imported; got \(result)")
    }
  }

  @Test("second ingest of the same bytes dedupes every row")
  func secondIngestDedupesAll() async throws {
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
    let result = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))
    if case .imported(_, let imported, let skipped) = result {
      #expect(imported.isEmpty)
      #expect(skipped == 4)  // 4 non-skip candidates all match existing
    } else {
      Issue.record("expected .imported")
    }
  }

  @Test("dropping onto a specific account bypasses the matcher")
  func dragToAccountBypassesMatcher() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    try await seedAccount(backend, id: accountId, name: "Dropped Target")
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = try cbaFixtureBytes()

    let result = await store.ingest(
      data: data,
      source: .droppedFile(
        url: URL(fileURLWithPath: "/tmp/cba.csv"),
        forcedAccountId: accountId))
    if case .imported(_, let imported, _) = result {
      #expect(imported.count == 4)
      // A profile was created on the fly.
      let profiles = try await backend.csvImportProfiles.fetchAll()
      #expect(profiles.count == 1)
      #expect(profiles[0].accountId == accountId)
    } else {
      Issue.record("expected .imported; got \(result)")
    }
  }

  // MARK: - Rules engine integration

  @Test("rules engine applies payee and category during ingest")
  func rulesApplyPayeeAndCategory() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    try await seedAccount(backend, id: accountId, name: "Cash")
    _ = try await seedProfile(backend, accountId: accountId)
    let category = Moolah.Category(id: UUID(), name: "Dining", parentId: nil)
    _ = try await backend.categories.create(category)
    let rule = ImportRule(
      name: "Coffee → Dining",
      position: 0,
      conditions: [.descriptionContains(["COFFEE"])],
      actions: [.setPayee("Café"), .setCategory(category.id)])
    _ = try await backend.importRules.create(rule)

    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = try cbaFixtureBytes()
    _ = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))

    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId), page: 0, pageSize: 50)
    let coffee = page.transactions.first(where: {
      $0.importOrigin?.rawDescription == "COFFEE HUT SYDNEY"
    })!
    #expect(coffee.payee == "Café")
    #expect(coffee.legs[0].categoryId == category.id)
  }

  @Test("markAsTransfer rewrites rule-matched rows into two-leg transfers")
  func rulesMarkAsTransfer() async throws {
    let (backend, _) = try TestBackend.create()
    let sourceAccount = UUID()
    let transferTarget = UUID()
    try await seedAccount(backend, id: sourceAccount, name: "Source")
    try await seedAccount(backend, id: transferTarget, name: "Target")
    _ = try await seedProfile(backend, accountId: sourceAccount)
    let rule = ImportRule(
      name: "CBA transfer",
      position: 0,
      conditions: [.descriptionContains(["COFFEE"])],
      actions: [.markAsTransfer(toAccountId: transferTarget)])
    _ = try await backend.importRules.create(rule)

    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = try cbaFixtureBytes()
    _ = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))

    // The coffee row became a two-leg transfer, source→target.
    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: sourceAccount), page: 0, pageSize: 50)
    let coffee = page.transactions.first(where: {
      $0.importOrigin?.rawDescription == "COFFEE HUT SYDNEY"
    })!
    #expect(coffee.legs.count == 2)
    #expect(coffee.legs.allSatisfy { $0.type == .transfer })
    let sum = coffee.legs.reduce(Decimal(0)) { $0 + $1.quantity }
    #expect(sum == 0)
  }

  // MARK: - Instrument correctness (Rule 11 / Rule 11a)

  @Test("placeholder cash legs are rewritten to the non-AUD target account's instrument")
  func placeholderLegRewriteNonAUD() async throws {
    let (backend, _) = try TestBackend.create()
    let eurAccount = UUID()
    let eur = Instrument.fiat(code: "EUR")
    try await seedAccount(backend, id: eurAccount, name: "EUR Bank", instrument: eur)
    _ = try await seedProfile(backend, accountId: eurAccount)

    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = try cbaFixtureBytes()
    _ = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))

    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: eurAccount), page: 0, pageSize: 50)
    #expect(!page.transactions.isEmpty)
    // Every persisted leg must carry the target account's instrument —
    // the parser's placeholder .AUD must never survive into persistence.
    for tx in page.transactions {
      for leg in tx.legs {
        #expect(leg.instrument == eur)
      }
    }
  }

  @Test("markAsTransfer across instruments stamps each leg with its own account's instrument")
  func markAsTransferCrossInstrument() async throws {
    let (backend, _) = try TestBackend.create()
    let audSource = UUID()
    let usdTarget = UUID()
    try await seedAccount(backend, id: audSource, name: "AUD Source", instrument: .AUD)
    try await seedAccount(backend, id: usdTarget, name: "USD Target", instrument: .USD)
    _ = try await seedProfile(backend, accountId: audSource)
    let rule = ImportRule(
      name: "Cross-currency transfer",
      position: 0,
      conditions: [.descriptionContains(["COFFEE"])],
      actions: [.markAsTransfer(toAccountId: usdTarget)])
    _ = try await backend.importRules.create(rule)

    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = try cbaFixtureBytes()
    _ = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))

    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: audSource), page: 0, pageSize: 50)
    let coffee = page.transactions.first(where: {
      $0.importOrigin?.rawDescription == "COFFEE HUT SYDNEY"
    })!
    #expect(coffee.legs.count == 2)
    let sourceLeg = coffee.legs.first(where: { $0.accountId == audSource })!
    let destinationLeg = coffee.legs.first(where: { $0.accountId == usdTarget })!
    #expect(sourceLeg.instrument == .AUD)
    // Rule 11a: destination leg carries the destination account's
    // instrument, NOT the source's. Without this fix, both legs would
    // be .AUD and the USD-target account would silently gain an AUD leg.
    #expect(destinationLeg.instrument == .USD)
  }

  @Test("skip rule drops rows from persistence")
  func rulesSkipDropsRows() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    try await seedAccount(backend, id: accountId, name: "Cash")
    _ = try await seedProfile(backend, accountId: accountId)
    let rule = ImportRule(
      name: "Skip coffee",
      position: 0,
      conditions: [.descriptionContains(["COFFEE"])],
      actions: [.skip])
    _ = try await backend.importRules.create(rule)

    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = try cbaFixtureBytes()
    let result = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))
    if case .imported(_, let imported, _) = result {
      // 4 non-skip candidates; 1 coffee row dropped by rule → 3 persisted.
      #expect(imported.count == 3)
      #expect(imported.allSatisfy { $0.importOrigin?.rawDescription != "COFFEE HUT SYDNEY" })
    } else {
      Issue.record("expected .imported")
    }
  }

  // MARK: - Error paths

  @Test("unparseable bytes land in failedFiles")
  func unparseableBytesLandFailed() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    try await seedAccount(backend, id: accountId, name: "Cash")
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Headers that won't match any parser, and a row the generic parser can't
    // make sense of either.
    let bytes = Data("Foo,Bar,Baz\n1,2,3\n".utf8)
    let result = await store.ingest(
      data: bytes,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/bad.csv"), securityScoped: false))
    if case .failed = result {
      #expect(store.failedFiles.count == 1)
      #expect(store.failedFiles[0].originalFilename == "bad.csv")
      #expect(store.failedFiles[0].error.contains("Headers"))
    } else {
      Issue.record("expected .failed; got \(result)")
    }
  }

  @Test("malformed row (invalid date) carries row index AND row content into failedFiles")
  func malformedRowSurfacesIndex() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    try await seedAccount(backend, id: accountId, name: "Cash")
    _ = try await seedProfile(backend, accountId: accountId)
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    // Valid shape on row 1, garbage date on row 2 (second data row).
    let bytes = Data(
      """
      Date,Description,Debit,Credit,Balance
      02/04/2024,COFFEE,5.50,,994.50
      not-a-date,COFFEE,5.50,,989.00
      """.utf8)
    let result = await store.ingest(
      data: bytes,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/bad.csv"), securityScoped: false))
    if case .failed = result {
      #expect(store.failedFiles.count == 1)
      #expect(store.failedFiles[0].offendingRowIndex == 2)
      #expect(store.failedFiles[0].offendingRow == ["not-a-date", "COFFEE", "5.50", "", "989.00"])
    } else {
      Issue.record("expected .failed")
    }
  }

  @Test("dismissPending clears the entry from both the store and staging")
  func dismissPendingClearsEntry() async throws {
    let (backend, _) = try TestBackend.create()
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = try cbaFixtureBytes()
    let result = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))
    guard case .needsSetup(let id) = result else {
      Issue.record("expected .needsSetup")
      return
    }
    #expect(store.pendingSetup.count == 1)
    await store.dismissPending(id: id)
    #expect(store.pendingSetup.isEmpty)
  }

  @Test("dismissFailed clears the entry from both the store and staging")
  func dismissFailedClearsEntry() async throws {
    let (backend, _) = try TestBackend.create()
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let bytes = Data("Foo,Bar,Baz\n1,2,3\n".utf8)
    _ = await store.ingest(
      data: bytes,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/bad.csv"), securityScoped: false))
    #expect(store.failedFiles.count == 1)
    let id = store.failedFiles[0].id
    await store.dismissFailed(id: id)
    #expect(store.failedFiles.isEmpty)
  }

  @Test("finishSetup re-reads staged bytes, creates profile, and imports")
  func finishSetupCompletesImport() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    try await seedAccount(backend, id: accountId, name: "Cash")
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = try cbaFixtureBytes()
    let first = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))
    guard case .needsSetup(let pendingId) = first else {
      Issue.record("expected .needsSetup on first ingest")
      return
    }

    // User confirms the setup form with a freshly-constructed profile.
    let newProfile = CSVImportProfile(
      accountId: accountId,
      parserIdentifier: "generic-bank",
      headerSignature: ["date", "description", "debit", "credit", "balance"])
    let second = await store.finishSetup(pendingId: pendingId, profile: newProfile)
    if case .imported(_, let imported, _) = second {
      #expect(imported.count == 4)
      #expect(store.pendingSetup.isEmpty)
      // Profile was persisted and routed.
      let profiles = try await backend.csvImportProfiles.fetchAll()
      #expect(profiles.count == 1)
    } else {
      Issue.record("expected .imported after finishSetup; got \(second)")
    }
  }

  // MARK: - ImportOrigin + profile update

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
