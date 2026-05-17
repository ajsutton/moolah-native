import Foundation
import Testing

@testable import Moolah

/// `CoinstashSyncSource` is the Coinstash path behind the shared
/// `AccountSyncSource` protocol. These tests pin: it claims only
/// `.coinstash` exchange accounts; a missing token maps to the
/// missing-credential error; an HTTP 401 maps to the invalid-credential
/// error — so `SyncedAccountStore` stays provider-agnostic.
struct CoinstashSyncSourceTests {
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)

  private func makeEngine() -> ExchangeSyncEngine {
    makeExchangeSyncEngine()
  }

  private func makeSource(
    client: any ExchangeClient, store: ExchangeTokenStore
  ) -> CoinstashSyncSource {
    CoinstashSyncSource(
      tokenStore: store, client: client,
      engine: makeEngine(),
      metadataResolverFactory: { _ in StubMetadataResolver([:]) })
  }

  @Test
  func handlesOnlyCoinstashExchange() {
    let src = makeSource(
      client: StubExchangeClient(), store: ExchangeTokenStore(synchronizable: false))
    let exchange = Account(
      name: "C", type: .exchange, instrument: .AUD,
      exchangeProvider: .coinstash)
    let crypto = Account(
      name: "W", type: .crypto, instrument: eth,
      walletAddress: "0x" + String(repeating: "a", count: 40), chainId: 1)
    // nil-provider exchange account (e.g. decoded from an older device):
    // the == .coinstash check is load-bearing for multi-provider
    // correctness — a future provider must not be claimed here.
    let nilProvider = Account(
      name: "X", type: .exchange, instrument: .AUD,
      exchangeProvider: nil)
    #expect(src.handles(exchange))
    #expect(!src.handles(crypto))
    #expect(!src.handles(nilProvider))
  }

  @Test
  func missingTokenThrowsMissingApiKey() async throws {
    let src = makeSource(
      client: StubExchangeClient(), store: ExchangeTokenStore(synchronizable: false))
    let exchange = Account(
      name: "C", type: .exchange, instrument: .AUD,
      exchangeProvider: .coinstash)
    let error = await #expect(throws: WalletSyncError.self) {
      _ = try await src.build(account: exchange)
    }
    #expect(error == .missingApiKey)
  }

  @Test
  func unauthorizedMapsToInvalidApiKey() async throws {
    let store = ExchangeTokenStore(synchronizable: false)
    let exchange = Account(
      name: "C", type: .exchange, instrument: .AUD,
      exchangeProvider: .coinstash)
    try store.save(token: "TOK", for: exchange.id)
    defer { store.delete(for: exchange.id) }
    let src = makeSource(
      client: StubExchangeClient(error: ExchangeClientError.unauthorized),
      store: store)
    let error = await #expect(throws: WalletSyncError.self) {
      _ = try await src.build(account: exchange)
    }
    #expect(error == .invalidApiKey)
  }
}
