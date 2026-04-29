import Foundation
import Testing

@testable import Moolah

@Suite("EarmarkStore -- Visibility & Multi-Instrument")
@MainActor
struct EarmarkStoreVisibilityTests {
  // MARK: - Show Hidden

  @Test("visibleEarmarks excludes hidden earmarks by default")
  func hiddenEarmarksExcluded() async throws {
    let visible = Earmark(name: "Visible", instrument: Instrument.defaultTestInstrument)
    let hidden = Earmark(
      name: "Hidden", instrument: Instrument.defaultTestInstrument, isHidden: true)
    let accountId = UUID()
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank, instrument: .defaultTestInstrument)
      ], in: database)
    TestBackend.seedWithTransactions(
      earmarks: [visible, hidden],
      amounts: [
        visible.id: (saved: 500, spent: 0),
        hidden.id: (saved: 300, spent: 0),
      ],
      accountId: accountId, in: database)
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
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(
          id: accountId, name: "Test", type: .bank, instrument: .defaultTestInstrument)
      ], in: database)
    TestBackend.seedWithTransactions(
      earmarks: [visible, hidden],
      amounts: [
        visible.id: (saved: 500, spent: 0),
        hidden.id: (saved: 300, spent: 0),
      ],
      accountId: accountId, in: database)
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
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      accounts: [
        Account(id: accountId, name: "Test", type: .bank, instrument: .USD)
      ], in: database)
    TestBackend.seedWithTransactions(
      earmarks: [usdEarmark],
      amounts: [usdEarmark.id: (saved: 500, spent: 0)],
      accountId: accountId, in: database, instrument: .USD)
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
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "AUD Checking", type: .bank, instrument: aud)],
      in: database)
    TestBackend.seedWithTransactions(
      earmarks: [Earmark(id: earmarkId, name: "US Travel", instrument: usd)],
      amounts: [earmarkId: (saved: 500, spent: 0)],
      accountId: accountId, in: database, instrument: aud)
    let store = EarmarkStore(
      repository: backend.earmarks,
      conversionService: FixedConversionService(rates: ["AUD": 2]),
      targetInstrument: aud)

    await store.load()

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
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      accounts: [Account(id: accountId, name: "AUD Checking", type: .bank, instrument: aud)],
      in: database)
    TestBackend.seedWithTransactions(
      earmarks: [Earmark(id: earmarkId, name: "Rainy Day", instrument: aud)],
      amounts: [earmarkId: (saved: 400, spent: 0)],
      accountId: accountId, in: database, instrument: aud)
    let store = EarmarkStore(
      repository: backend.earmarks,
      conversionService: FixedConversionService(rates: ["AUD": 2]),
      targetInstrument: aud)
    await store.load()

    let before = try #require(store.convertedBalance(for: earmarkId))
    #expect(before.instrument == aud)
    #expect(before.quantity == 400)

    let current = try #require(store.earmarks.by(id: earmarkId))
    var changed = current
    changed.instrument = usd
    let updated = await store.update(changed)
    #expect(updated?.instrument == usd)

    let after = try #require(store.convertedBalance(for: earmarkId))
    #expect(after.instrument == usd)
    #expect(after.quantity == 800)
  }
}
