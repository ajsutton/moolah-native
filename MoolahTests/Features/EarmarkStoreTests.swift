import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("EarmarkStore")
@MainActor
struct EarmarkStoreTests {
  @Test func testPopulatesFromRepository() async throws {
    let earmark = Earmark(name: "Holiday Fund", instrument: Instrument.defaultTestInstrument)
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seedWithTransactions(
      earmarks: [earmark],
      amounts: [earmark.id: (saved: 500, spent: 0)],
      accountId: accountId, in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    await store.load()

    #expect(store.earmarks.count == 1)
    #expect(store.earmarks.first?.name == "Holiday Fund")
  }

  @Test func testSortingByPosition() async throws {
    let e1 = Earmark(name: "E1", instrument: Instrument.defaultTestInstrument, position: 2)
    let e2 = Earmark(name: "E2", instrument: Instrument.defaultTestInstrument, position: 1)
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seedWithTransactions(
      earmarks: [e1, e2],
      amounts: [
        e1.id: (saved: 100, spent: 0),
        e2.id: (saved: 200, spent: 0),
      ],
      accountId: accountId, in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    await store.load()

    #expect(store.earmarks.count == 2)
    #expect(store.earmarks[0].name == "E2")
    #expect(store.earmarks[1].name == "E1")
  }

  @Test func testEarmarkInstrumentSetCorrectly() async throws {
    let e1 = Earmark(name: "Holiday", instrument: Instrument.defaultTestInstrument)
    let e2 = Earmark(name: "Car Repair", instrument: Instrument.defaultTestInstrument)
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank, instrument: .defaultTestInstrument)
      ], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [e1, e2],
      amounts: [
        e1.id: (saved: 500, spent: 0),
        e2.id: (saved: 300, spent: 0),
      ],
      accountId: accountId, in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    await store.load()

    #expect(store.earmarks.count == 2)
    #expect(store.earmarks[0].instrument == Instrument.defaultTestInstrument)
    #expect(store.earmarks[1].instrument == Instrument.defaultTestInstrument)
  }

  // MARK: - applyDelta (position-based)

  @Test func testApplyDeltaAdjustsPositionsAndBalance() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank, instrument: .defaultTestInstrument)
      ], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [Earmark(id: earmarkId, name: "Holiday Fund", instrument: instrument)],
      amounts: [earmarkId: (saved: 500, spent: 0)],
      accountId: accountId, in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    store.applyDelta(
      earmarkDeltas: [earmarkId: [instrument: -100]],
      savedDeltas: [:],
      spentDeltas: [earmarkId: [instrument: 100]]
    )

    #expect(store.earmarks.by(id: earmarkId)?.positions.first?.quantity == 400)
    #expect(store.earmarks.by(id: earmarkId)?.savedPositions.first?.quantity == 500)
    #expect(store.earmarks.by(id: earmarkId)?.spentPositions.first?.quantity == 100)
  }

  @Test func testApplyDeltaWithSavedIncreasesBalance() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank, instrument: .defaultTestInstrument)
      ], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [Earmark(id: earmarkId, name: "Holiday Fund", instrument: instrument)],
      amounts: [earmarkId: (saved: 500, spent: 0)],
      accountId: accountId, in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    store.applyDelta(
      earmarkDeltas: [earmarkId: [instrument: 200]],
      savedDeltas: [earmarkId: [instrument: 200]],
      spentDeltas: [:]
    )

    #expect(store.earmarks.by(id: earmarkId)?.positions.first?.quantity == 700)
    #expect(store.earmarks.by(id: earmarkId)?.savedPositions.first?.quantity == 700)
  }

  @Test func testApplyDeltaAffectsMultipleEarmarks() async throws {
    let earmark1Id = UUID()
    let earmark2Id = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank, instrument: .defaultTestInstrument)
      ], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [
        Earmark(id: earmark1Id, name: "Holiday", instrument: instrument),
        Earmark(id: earmark2Id, name: "Car", instrument: instrument),
      ],
      amounts: [
        earmark1Id: (saved: 500, spent: 0),
        earmark2Id: (saved: 300, spent: 0),
      ],
      accountId: accountId, in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    store.applyDelta(
      earmarkDeltas: [
        earmark1Id: [instrument: -100],
        earmark2Id: [instrument: 50],
      ],
      savedDeltas: [earmark2Id: [instrument: 50]],
      spentDeltas: [earmark1Id: [instrument: 100]]
    )

    #expect(store.earmarks.by(id: earmark1Id)?.positions.first?.quantity == 400)
    #expect(store.earmarks.by(id: earmark1Id)?.spentPositions.first?.quantity == 100)
    #expect(store.earmarks.by(id: earmark2Id)?.positions.first?.quantity == 350)
    #expect(store.earmarks.by(id: earmark2Id)?.savedPositions.first?.quantity == 350)
  }

  // MARK: - convertedTotalBalance

  @Test func testConvertedTotalBalanceNilBeforeLoad() async throws {
    let (backend, _) = try TestBackend.create()
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    #expect(store.convertedTotalBalance == nil)
  }

  @Test func testConvertedTotalBalancePopulatedAfterLoad() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank, instrument: .defaultTestInstrument)
      ], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [Earmark(id: earmarkId, name: "Holiday Fund", instrument: instrument)],
      amounts: [earmarkId: (saved: 500, spent: 0)],
      accountId: accountId, in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    await store.load()
    try await Task.sleep(for: .milliseconds(50))

    #expect(store.convertedTotalBalance != nil)
    #expect(store.convertedTotalBalance?.quantity == 500)
  }

  @Test func testConvertedTotalBalanceExcludesNegativeEarmarks() async throws {
    let positiveId = UUID()
    let negativeId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank, instrument: .defaultTestInstrument)
      ], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [
        Earmark(id: positiveId, name: "Holiday Fund", instrument: instrument),
        Earmark(id: negativeId, name: "Investments", instrument: instrument),
      ],
      amounts: [
        positiveId: (saved: 500, spent: 0),
        negativeId: (saved: -18950, spent: 0),
      ],
      accountId: accountId, in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    await store.load()
    try await Task.sleep(for: .milliseconds(50))

    // Individual balances should reflect true values
    #expect(store.convertedBalance(for: positiveId)?.quantity == 500)
    #expect(store.convertedBalance(for: negativeId)?.quantity == -18950)

    // Total should clamp negative earmarks to 0, so total = 500 (not 500 - 18950)
    #expect(store.convertedTotalBalance?.quantity == 500)
  }

  @Test func testConvertedTotalBalanceUpdatesAfterApplyDelta() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank, instrument: .defaultTestInstrument)
      ], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [Earmark(id: earmarkId, name: "Holiday Fund", instrument: instrument)],
      amounts: [earmarkId: (saved: 500, spent: 0)],
      accountId: accountId, in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()
    try await Task.sleep(for: .milliseconds(50))
    #expect(store.convertedTotalBalance?.quantity == 500)

    store.applyDelta(
      earmarkDeltas: [earmarkId: [instrument: -100]],
      savedDeltas: [:],
      spentDeltas: [earmarkId: [instrument: 100]]
    )
    try await Task.sleep(for: .milliseconds(50))

    #expect(store.convertedTotalBalance?.quantity == 400)
  }

  // MARK: - Per-earmark converted amounts

  @Test func testConvertedBalancePerEarmarkPopulatedAfterLoad() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank, instrument: .defaultTestInstrument)
      ], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [Earmark(id: earmarkId, name: "Holiday Fund", instrument: instrument)],
      amounts: [earmarkId: (saved: 500, spent: 0)],
      accountId: accountId, in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    await store.load()
    try await Task.sleep(for: .milliseconds(50))

    #expect(store.convertedBalance(for: earmarkId)?.quantity == 500)
    #expect(store.convertedSaved(for: earmarkId)?.quantity == 500)
    #expect(store.convertedSpent(for: earmarkId)?.quantity == 0)
  }

  @Test func testConvertedBalancePerEarmarkUpdatesAfterDelta() async throws {
    let earmarkId = UUID()
    let accountId = UUID()
    let instrument = Instrument.defaultTestInstrument
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank, instrument: .defaultTestInstrument)
      ], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [Earmark(id: earmarkId, name: "Holiday Fund", instrument: instrument)],
      amounts: [earmarkId: (saved: 500, spent: 0)],
      accountId: accountId, in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()
    try await Task.sleep(for: .milliseconds(50))

    store.applyDelta(
      earmarkDeltas: [earmarkId: [instrument: -100]],
      savedDeltas: [:],
      spentDeltas: [earmarkId: [instrument: 100]]
    )
    try await Task.sleep(for: .milliseconds(50))

    #expect(store.convertedBalance(for: earmarkId)?.quantity == 400)
    #expect(store.convertedSpent(for: earmarkId)?.quantity == 100)
  }

  // MARK: - reorderEarmarks

  @Test func testReorderEarmarksUpdatesPositions() async throws {
    let e0 = Earmark(name: "First", instrument: .defaultTestInstrument, position: 0)
    let e1 = Earmark(name: "Second", instrument: .defaultTestInstrument, position: 1)
    let e2 = Earmark(name: "Third", instrument: .defaultTestInstrument, position: 2)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [e0, e1, e2], in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    await store.reorderEarmarks(from: IndexSet(integer: 2), to: 0)

    #expect(store.visibleEarmarks[0].name == "Third")
    #expect(store.visibleEarmarks[1].name == "First")
    #expect(store.visibleEarmarks[2].name == "Second")
    #expect(store.visibleEarmarks[0].position == 0)
    #expect(store.visibleEarmarks[1].position == 1)
    #expect(store.visibleEarmarks[2].position == 2)
  }

  @Test func testReorderEarmarksSkipsHiddenEarmarks() async throws {
    let e0 = Earmark(name: "Visible1", instrument: .defaultTestInstrument, position: 0)
    let e1 = Earmark(
      name: "Hidden", instrument: .defaultTestInstrument, isHidden: true, position: 1)
    let e2 = Earmark(name: "Visible2", instrument: .defaultTestInstrument, position: 2)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [e0, e1, e2], in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    await store.reorderEarmarks(from: IndexSet(integer: 1), to: 0)

    #expect(store.visibleEarmarks[0].name == "Visible2")
    #expect(store.visibleEarmarks[1].name == "Visible1")
    let hidden = store.earmarks.ordered.first { $0.isHidden }
    #expect(hidden?.position == 1)
  }

  @Test func testReorderSingleEarmarkIsNoOp() async throws {
    let e0 = Earmark(name: "Only", instrument: .defaultTestInstrument, position: 0)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [e0], in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    await store.reorderEarmarks(from: IndexSet(integer: 0), to: 0)

    #expect(store.visibleEarmarks.count == 1)
    #expect(store.visibleEarmarks[0].position == 0)
  }

  @Test func testReorderEmptyListIsNoOp() async throws {
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [], in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    await store.reorderEarmarks(from: IndexSet(integer: 0), to: 0)

    #expect(store.visibleEarmarks.isEmpty)
  }

  @Test func testReorderPersistsToRepository() async throws {
    let e0 = Earmark(name: "First", instrument: .defaultTestInstrument, position: 0)
    let e1 = Earmark(name: "Second", instrument: .defaultTestInstrument, position: 1)
    let e2 = Earmark(name: "Third", instrument: .defaultTestInstrument, position: 2)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [e0, e1, e2], in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    await store.reorderEarmarks(from: IndexSet(integer: 2), to: 0)

    let persisted = try await backend.earmarks.fetchAll().sorted { $0.position < $1.position }
    #expect(persisted[0].name == "Third")
    #expect(persisted[1].name == "First")
    #expect(persisted[2].name == "Second")
    #expect(persisted[0].position == 0)
    #expect(persisted[1].position == 1)
    #expect(persisted[2].position == 2)
  }

  // MARK: - create / update

  @Test func testCreateAddsEarmark() async throws {
    let (backend, _) = try TestBackend.create()
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    let earmark = Earmark(name: "New Fund", instrument: .defaultTestInstrument)
    let created = await store.create(earmark)

    #expect(created != nil)
    #expect(created?.name == "New Fund")
    #expect(store.earmarks.count == 1)
    #expect(store.earmarks.first?.name == "New Fund")
  }

  @Test func testCreateReturnsNilOnFailure() async throws {
    let store = EarmarkStore(
      repository: FailingEarmarkRepository(),
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    let result = await store.create(Earmark(name: "Fails", instrument: .defaultTestInstrument))

    #expect(result == nil)
    #expect(store.error != nil)
  }

  @Test func testCreateReloadsAfterSuccess() async throws {
    let (backend, _) = try TestBackend.create()
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    let e1 = Earmark(name: "First", instrument: .defaultTestInstrument)
    _ = await store.create(e1)
    let e2 = Earmark(name: "Second", instrument: .defaultTestInstrument)
    _ = await store.create(e2)

    #expect(store.earmarks.count == 2)
    #expect(store.earmarks.by(id: e1.id) != nil)
    #expect(store.earmarks.by(id: e2.id) != nil)
  }

  @Test func testUpdateModifiesEarmark() async throws {
    let earmark = Earmark(name: "Holiday Fund", instrument: .defaultTestInstrument)
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(earmarks: [earmark], in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await store.load()

    var modified = earmark
    modified.name = "Vacation Fund"
    let updated = await store.update(modified)

    #expect(updated != nil)
    #expect(updated?.name == "Vacation Fund")
    #expect(store.earmarks.by(id: earmark.id)?.name == "Vacation Fund")
  }

  @Test func testUpdateReturnsNilOnFailure() async throws {
    let store = EarmarkStore(
      repository: FailingEarmarkRepository(),
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    let result = await store.update(Earmark(name: "Fails", instrument: .defaultTestInstrument))

    #expect(result == nil)
    #expect(store.error != nil)
  }

  // MARK: - Show Hidden

  @Test("visibleEarmarks excludes hidden earmarks by default")
  func hiddenEarmarksExcluded() async throws {
    let visible = Earmark(name: "Visible", instrument: Instrument.defaultTestInstrument)
    let hidden = Earmark(
      name: "Hidden", instrument: Instrument.defaultTestInstrument, isHidden: true)
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank, instrument: .defaultTestInstrument)
      ], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [visible, hidden],
      amounts: [
        visible.id: (saved: 500, spent: 0),
        hidden.id: (saved: 300, spent: 0),
      ],
      accountId: accountId, in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    await store.load()

    #expect(store.visibleEarmarks.count == 1)
    #expect(store.visibleEarmarks[0].name == "Visible")
  }

  @Test("visibleEarmarks includes hidden earmarks when showHidden is true")
  func hiddenEarmarksIncluded() async throws {
    let visible = Earmark(name: "Visible", instrument: Instrument.defaultTestInstrument)
    let hidden = Earmark(
      name: "Hidden", instrument: Instrument.defaultTestInstrument, isHidden: true)
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank, instrument: .defaultTestInstrument)
      ], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [visible, hidden],
      amounts: [
        visible.id: (saved: 500, spent: 0),
        hidden.id: (saved: 300, spent: 0),
      ],
      accountId: accountId, in: container)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    await store.load()
    store.showHidden = true

    #expect(store.visibleEarmarks.count == 2)
  }

  // MARK: - Multi-instrument earmarks

  @Test("USD earmark is loaded with USD instrument intact")
  func loadEarmarkWithUSDInstrument() async throws {
    let usdEarmark = Earmark(name: "US Travel", instrument: .USD)
    let accountId = UUID()
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(id: accountId, name: "Test", type: .bank, instrument: .USD)
      ], in: container)
    TestBackend.seedWithTransactions(
      earmarks: [usdEarmark],
      amounts: [usdEarmark.id: (saved: 500, spent: 0)],
      accountId: accountId, in: container, instrument: .USD)
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FixedConversionService(),
      targetInstrument: .USD)

    await store.load()
    #expect(store.earmarks.count == 1)
    #expect(store.earmarks.first?.instrument == .USD)
  }

  @Test("Earmarks created with different instruments round-trip through repository")
  func multipleEarmarksWithDifferentInstruments() async throws {
    // Direct repository check — avoids triggering store-level aggregation that presumes
    // a single profile currency.
    let audEm = Earmark(name: "AUD Fund", instrument: .AUD)
    let usdEm = Earmark(name: "USD Fund", instrument: .USD)
    let (backend, _) = try TestBackend.create()
    _ = try await backend.earmarks.create(audEm)
    _ = try await backend.earmarks.create(usdEm)

    let all = try await backend.earmarks.fetchAll()
    #expect(all.count == 2)
    let aud = try #require(all.first { $0.id == audEm.id })
    let usd = try #require(all.first { $0.id == usdEm.id })
    #expect(aud.instrument == .AUD)
    #expect(usd.instrument == .USD)
  }

  @Test("Earmark in non-profile currency converts AUD positions into the earmark's currency")
  func convertedBalanceForNonProfileEarmark() async throws {
    // Profile (target) is AUD. Earmark is USD. Positions come from an AUD account.
    // With USD rate 2.0 (AUD → USD: 100 AUD * 2 = 200 USD), a 500 AUD position should show
    // as 1000 USD on the earmark.
    let earmarkId = UUID()
    let accountId = UUID()
    let aud = Instrument.AUD
    let usd = Instrument.USD
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "AUD Checking", type: .bank, instrument: aud)],
      in: container)
    TestBackend.seedWithTransactions(
      earmarks: [Earmark(id: earmarkId, name: "US Travel", instrument: usd)],
      amounts: [earmarkId: (saved: 500, spent: 0)],
      accountId: accountId, in: container, instrument: aud)
    let store = EarmarkStore(
      repository: backend.earmarks,
      conversionService: FixedConversionService(rates: ["AUD": 2]),
      targetInstrument: aud)

    await store.load()
    try await Task.sleep(for: .milliseconds(50))

    let balance = try #require(store.convertedBalance(for: earmarkId))
    #expect(balance.instrument == usd)
    #expect(balance.quantity == 1000)
  }

  @Test("Updating earmark instrument re-expresses its converted balance in the new currency")
  func updateEarmarkInstrumentReExpressesConvertedBalance() async throws {
    // Start: earmark in AUD with a 400 AUD position; balance displays as 400 AUD.
    // Update: switch the earmark to USD. The position is still AUD but the store should
    // reconvert it into USD for display. With rate 2.0, 400 AUD → 800 USD.
    let earmarkId = UUID()
    let accountId = UUID()
    let aud = Instrument.AUD
    let usd = Instrument.USD
    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "AUD Checking", type: .bank, instrument: aud)],
      in: container)
    TestBackend.seedWithTransactions(
      earmarks: [Earmark(id: earmarkId, name: "Rainy Day", instrument: aud)],
      amounts: [earmarkId: (saved: 400, spent: 0)],
      accountId: accountId, in: container, instrument: aud)
    let store = EarmarkStore(
      repository: backend.earmarks,
      conversionService: FixedConversionService(rates: ["AUD": 2]),
      targetInstrument: aud)
    await store.load()
    try await Task.sleep(for: .milliseconds(50))

    let before = try #require(store.convertedBalance(for: earmarkId))
    #expect(before.instrument == aud)
    #expect(before.quantity == 400)

    let current = try #require(store.earmarks.by(id: earmarkId))
    var changed = current
    changed.instrument = usd
    let updated = await store.update(changed)
    #expect(updated?.instrument == usd)
    try await Task.sleep(for: .milliseconds(50))

    let after = try #require(store.convertedBalance(for: earmarkId))
    #expect(after.instrument == usd)
    #expect(after.quantity == 800)
  }
}

// MARK: - Partial Conversion Failures

@Suite("EarmarkStore -- Partial Conversion Failures")
@MainActor
struct EarmarkStorePartialConversionTests {

  /// When one earmark's positions can't be converted to its own instrument,
  /// other earmarks whose conversions succeed still appear in
  /// `convertedBalances`. The aggregate `convertedTotalBalance` stays nil
  /// because we cannot accurately sum a set with a missing value.
  @Test func earmarkBalancePopulatesEvenWhenAnotherFails() async throws {
    let aud = Instrument.AUD
    let usd = Instrument.USD
    let eur = Instrument.fiat(code: "EUR")
    let accountId = UUID()
    let healthyEarmark = Earmark(name: "Holiday", instrument: aud)
    let mixedEarmark = Earmark(name: "Mixed", instrument: eur)

    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank, instrument: aud)],
      in: container)
    TestBackend.seed(earmarks: [healthyEarmark, mixedEarmark], in: container)

    // Healthy earmark: AUD positions only.
    let healthyTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: Decimal(300),
          type: .income, earmarkId: healthyEarmark.id)
      ])
    // Mixed earmark: EUR + USD; USD → EUR conversion will fail.
    let mixedEurTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: eur, quantity: Decimal(100),
          type: .income, earmarkId: mixedEarmark.id)
      ])
    let mixedUsdTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: usd, quantity: Decimal(50),
          type: .income, earmarkId: mixedEarmark.id)
      ])
    TestBackend.seed(transactions: [healthyTx, mixedEurTx, mixedUsdTx], in: container)

    let conversion = FailingConversionService(failingInstrumentIds: ["USD"])
    let store = EarmarkStore(
      repository: backend.earmarks,
      conversionService: conversion,
      targetInstrument: aud,
      retryDelay: .seconds(60))

    await store.load()
    try await Task.sleep(for: .milliseconds(50))

    #expect(store.convertedBalance(for: healthyEarmark.id)?.quantity == 300)
    #expect(store.convertedBalance(for: mixedEarmark.id) == nil)
    #expect(store.convertedTotalBalance == nil)
  }

  /// After conversion service recovers, retry populates the previously
  /// failing earmark balance and the aggregate total.
  @Test func conversionFailuresAreRetriedAfterDelay() async throws {
    let aud = Instrument.AUD
    let eur = Instrument.fiat(code: "EUR")
    let accountId = UUID()
    let audEarmark = Earmark(name: "AUD", instrument: aud)
    let eurEarmark = Earmark(name: "EUR", instrument: eur)

    let (backend, container) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "Test", type: .bank, instrument: aud)],
      in: container)
    TestBackend.seed(earmarks: [audEarmark, eurEarmark], in: container)

    let audTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: Decimal(400),
          type: .income, earmarkId: audEarmark.id)
      ])
    let eurTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: eur, quantity: Decimal(200),
          type: .income, earmarkId: eurEarmark.id)
      ])
    TestBackend.seed(transactions: [audTx, eurTx], in: container)

    let conversion = FailingConversionService(failingInstrumentIds: ["EUR"])
    let store = EarmarkStore(
      repository: backend.earmarks,
      conversionService: conversion,
      targetInstrument: aud,
      retryDelay: .milliseconds(20))

    await store.load()
    try await Task.sleep(for: .milliseconds(50))

    // Aggregate cannot be computed (EUR → AUD fails). Per-earmark balances
    // are still displayed in their own currency where no conversion is
    // needed.
    #expect(store.convertedTotalBalance == nil)

    await conversion.setFailing([])

    try await waitForCondition(timeout: .seconds(2)) {
      store.convertedTotalBalance != nil
    }

    // 400 AUD + 200 EUR (1:1 fallback) = 600 AUD
    #expect(store.convertedTotalBalance?.quantity == 600)
    #expect(store.convertedBalance(for: audEarmark.id)?.quantity == 400)
    #expect(store.convertedBalance(for: eurEarmark.id)?.quantity == 200)
  }
}

@MainActor
private func waitForCondition(
  timeout: Duration,
  _ predicate: @MainActor () -> Bool
) async throws {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while ContinuousClock.now < deadline {
    if predicate() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("Timed out waiting for condition")
}

// MARK: - Test helpers

private struct FailingEarmarkRepository: EarmarkRepository {
  func fetchAll() async throws -> [Earmark] {
    throw BackendError.networkUnavailable
  }

  func create(_ earmark: Earmark) async throws -> Earmark {
    throw BackendError.networkUnavailable
  }

  func update(_ earmark: Earmark) async throws -> Earmark {
    throw BackendError.networkUnavailable
  }

  func fetchBudget(earmarkId: UUID) async throws -> [EarmarkBudgetItem] {
    throw BackendError.networkUnavailable
  }

  func setBudget(earmarkId: UUID, categoryId: UUID, amount: InstrumentAmount) async throws {
    throw BackendError.networkUnavailable
  }
}
