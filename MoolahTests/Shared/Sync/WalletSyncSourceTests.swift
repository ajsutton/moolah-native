import Foundation
import Testing

@testable import Moolah

/// `WalletSyncSource` is the crypto path expressed through the shared
/// `AccountSyncSource` protocol. These tests pin the `handles(_:)`
/// predicate: a crypto account needs both a wallet address and a known
/// chain; an exchange account is never claimed by the wallet source.
struct WalletSyncSourceTests {
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)

  /// Returns a fixed `WalletSyncBuildResult` regardless of input — the
  /// `handles` tests never reach `build`, and `build`-path coverage is
  /// the existing `WalletSyncEngineTests`' job.
  private struct StubWalletEngine: WalletSyncBuilding {
    func build(
      account: Account, chain: ChainConfig
    ) async throws -> WalletSyncBuildResult {
      WalletSyncBuildResult(candidates: [], headBlockNumber: 0)
    }
  }

  @Test
  func handlesCryptoWithChainAndAddress() {
    let src = WalletSyncSource(engine: StubWalletEngine(), chains: ChainConfig.all)
    let ok = Account(
      name: "W", type: .crypto, instrument: eth,
      walletAddress: "0x" + String(repeating: "a", count: 40), chainId: 1)
    let noChain = Account(
      name: "W", type: .crypto, instrument: eth,
      walletAddress: "0x" + String(repeating: "a", count: 40), chainId: nil)
    let exchange = Account(
      name: "C", type: .exchange, instrument: .AUD,
      exchangeProvider: .coinstash)
    #expect(src.handles(ok))
    #expect(!src.handles(noChain))
    #expect(!src.handles(exchange))
  }
}
