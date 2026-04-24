import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("InstrumentRegistryRepository — Contract")
@MainActor
struct InstrumentRegistryContractTests {
  // Test fixture: builds an in-memory CloudKitInstrumentRegistryRepository
  // with captured sync-queue hooks, matching the public init signature.
  @MainActor
  final class HookCapture {
    var changedIds: [String] = []
    var deletedIds: [String] = []
  }

  @MainActor
  func makeSubject() throws -> (
    repo: CloudKitInstrumentRegistryRepository,
    hooks: HookCapture
  ) {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
      for: InstrumentRecord.self,
      configurations: config
    )
    let hooks = HookCapture()
    let repo = CloudKitInstrumentRegistryRepository(
      modelContainer: container,
      onRecordChanged: { [hooks] id in Task { @MainActor in hooks.changedIds.append(id) } },
      onRecordDeleted: { [hooks] id in Task { @MainActor in hooks.deletedIds.append(id) } }
    )
    return (repo, hooks)
  }

  @Test("all() on a fresh profile returns every ISO currency and zero non-fiat rows")
  func freshProfileIsFiatOnly() async throws {
    let (repo, _) = try makeSubject()
    let all = try await repo.all()
    let fiats = all.filter { $0.kind == .fiatCurrency }
    let nonFiats = all.filter { $0.kind != .fiatCurrency }
    #expect(fiats.count == Locale.Currency.isoCurrencies.count)
    #expect(nonFiats.isEmpty)
    #expect(all.contains { $0.id == "AUD" })
    #expect(all.contains { $0.id == "USD" })
  }

  @Test("registerStock makes the stock appear in all()")
  func registerStockAppears() async throws {
    let (repo, _) = try makeSubject()
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    try await repo.registerStock(bhp)
    let all = try await repo.all()
    #expect(all.contains { $0.id == "ASX:BHP.AX" })
  }

  @Test("registerCrypto round-trips all eight crypto fields + three mapping fields")
  func registerCryptoRoundTrip() async throws {
    let (repo, _) = try makeSubject()
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH",
      name: "Ethereum", decimals: 18)
    let mapping = CryptoProviderMapping(
      instrumentId: eth.id,
      coingeckoId: "ethereum",
      cryptocompareSymbol: "ETH",
      binanceSymbol: "ETHUSDT")
    try await repo.registerCrypto(eth, mapping: mapping)

    let regs = try await repo.allCryptoRegistrations()
    let reg = try #require(regs.first { $0.id == eth.id })
    #expect(reg.instrument.chainId == 1)
    #expect(reg.instrument.contractAddress == nil)
    #expect(reg.instrument.ticker == "ETH")
    #expect(reg.instrument.name == "Ethereum")
    #expect(reg.instrument.decimals == 18)
    #expect(reg.mapping.coingeckoId == "ethereum")
    #expect(reg.mapping.cryptocompareSymbol == "ETH")
    #expect(reg.mapping.binanceSymbol == "ETHUSDT")
  }

  @Test("registerCrypto with existing id upserts the mapping")
  func registerCryptoUpserts() async throws {
    let (repo, _) = try makeSubject()
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH",
      name: "Ethereum", decimals: 18)
    let first = CryptoProviderMapping(
      instrumentId: eth.id,
      coingeckoId: "ethereum", cryptocompareSymbol: nil, binanceSymbol: nil)
    let second = CryptoProviderMapping(
      instrumentId: eth.id,
      coingeckoId: "ethereum", cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT")
    try await repo.registerCrypto(eth, mapping: first)
    try await repo.registerCrypto(eth, mapping: second)

    let regs = try await repo.allCryptoRegistrations()
    #expect(regs.count == 1)
    #expect(regs.first?.mapping.cryptocompareSymbol == "ETH")
    #expect(regs.first?.mapping.binanceSymbol == "ETHUSDT")
  }

  @Test("allCryptoRegistrations skips rows whose three mapping fields are all nil")
  func allCryptoSkipsMissingMapping() async throws {
    let (repo, _) = try makeSubject()
    // Simulate an ensureInstrument-auto-inserted row: crypto kind, but no
    // mapping fields.
    let context = repo.modelContainer.mainContext
    let ghost = InstrumentRecord(
      id: "1:native",
      kind: "cryptoToken",
      name: "Ethereum",
      decimals: 18,
      ticker: "ETH",
      chainId: 1,
      contractAddress: nil
    )
    context.insert(ghost)
    try context.save()

    let regs = try await repo.allCryptoRegistrations()
    #expect(regs.isEmpty)
    // But it still appears in all() — it's a valid instrument, just unpriced.
    let all = try await repo.all()
    #expect(all.contains { $0.id == "1:native" && $0.kind == .cryptoToken })
  }

  @Test("remove deletes the row and is a no-op for fiat + unknown ids")
  func removeBehaviour() async throws {
    let (repo, _) = try makeSubject()
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    try await repo.registerStock(bhp)

    try await repo.remove(id: bhp.id)
    let all = try await repo.all()
    #expect(all.contains { $0.id == bhp.id } == false)

    // No-op cases: must not throw.
    try await repo.remove(id: "AUD")  // fiat id
    try await repo.remove(id: "DOES_NOT_EXIST:FOO")  // unknown id
  }

  @Test("sync-queue hook fires on registerStock / registerCrypto / remove")
  func syncHooksFire() async throws {
    let (repo, hooks) = try makeSubject()
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    try await repo.registerStock(bhp)
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH",
      name: "Ethereum", decimals: 18)
    try await repo.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum",
        cryptocompareSymbol: nil, binanceSymbol: nil))
    try await repo.remove(id: bhp.id)

    // Drain pending @MainActor hops from the sync-queue hook closures. Not
    // strictly deterministic — if CI flakes, consider making the hooks
    // async/awaitable so the test can `await` them directly.
    try await Task.sleep(for: .milliseconds(50))

    #expect(hooks.changedIds == ["ASX:BHP.AX", "1:native"])
    #expect(hooks.deletedIds == ["ASX:BHP.AX"])
  }

  @Test("sync-queue hook does not fire for fiat register or unknown remove")
  func syncHooksSkipNoops() async throws {
    let (repo, hooks) = try makeSubject()
    // Fiat register is rejected by the type-level split — there is no
    // registerFiat. But unknown remove is a runtime no-op.
    try await repo.remove(id: "DOES_NOT_EXIST:FOO")
    // Drain pending @MainActor hops from the sync-queue hook closures. Not
    // strictly deterministic — if CI flakes, consider making the hooks
    // async/awaitable so the test can `await` them directly.
    try await Task.sleep(for: .milliseconds(50))
    #expect(hooks.changedIds.isEmpty)
    #expect(hooks.deletedIds.isEmpty)
  }

  @Test("observeChanges fans out to multiple consumers")
  func observeChangesFanOut() async throws {
    let (repo, _) = try makeSubject()
    let streamA = repo.observeChanges()
    let streamB = repo.observeChanges()
    var iteratorA = streamA.makeAsyncIterator()
    var iteratorB = streamB.makeAsyncIterator()

    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    Task { try? await repo.registerStock(bhp) }

    _ = await iteratorA.next()
    _ = await iteratorB.next()
    // If both iterators advanced we know both got a yield.
  }

  @Test("cancelled observeChanges consumer does not block sibling consumers")
  func observeChangesCancellation() async throws {
    let (repo, _) = try makeSubject()
    let alive = repo.observeChanges()
    var aliveIterator = alive.makeAsyncIterator()

    let cancelTask = Task {
      var dropped = repo.observeChanges().makeAsyncIterator()
      _ = await dropped.next()
    }
    cancelTask.cancel()

    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    Task { try? await repo.registerStock(bhp) }

    _ = await aliveIterator.next()  // would hang if the cancelled consumer
    // blocked the fan-out.
  }
}
