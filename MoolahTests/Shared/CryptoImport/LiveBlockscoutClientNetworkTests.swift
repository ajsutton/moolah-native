// MoolahTests/Shared/CryptoImport/LiveBlockscoutClientNetworkTests.swift
import Foundation
import Testing

@testable import Moolah

/// Smoke tests that call the **real** public Blockscout instances to verify
/// that our wire-format structs (`BlockscoutTransaction`) decode correctly
/// against live responses.
///
/// # Gating
///
/// The neighbouring `LiveAlchemy*` suites are URLProtocol-stubbed — "Live"
/// there names the real `LiveAlchemyClient` type under test, not live
/// network calls, so they need no gate. This suite intentionally hits the
/// real public Blockscout endpoints, which would make CI flaky (outages,
/// rate-limits, maintenance), so every test is gated behind
/// `.enabled(if: liveNetworkEnabled)`.
///
/// Default `just test` / `just test-mac` in CI do NOT set this env var, so
/// every test in this suite is **skipped** (not failed) by default.
///
/// To run the live tests locally, use the `TEST_RUNNER_` prefix so that
/// xcodebuild (which `just test-mac` calls internally) forwards the variable
/// to the test host process (plain env-var prefix does NOT reach the test
/// binary — xcodebuild requires the `TEST_RUNNER_*` convention):
/// ```bash
/// TEST_RUNNER_MOOLAH_LIVE_NETWORK_TESTS=1 just test-mac LiveBlockscoutClientNetworkTests
/// ```
///
/// The address under test (`0xa4b572ea1b6f734fc88a0a004c5301f8dad54d60`) is
/// the wallet from GitHub issues #918/#919 — known to have native ETH
/// history on Ethereum, OP Mainnet, and Base.
@Suite("LiveBlockscoutClient — live network smoke tests (gated)")
struct LiveBlockscoutClientNetworkTests {
  private static let liveNetworkEnabled =
    ProcessInfo.processInfo.environment["MOOLAH_LIVE_NETWORK_TESTS"] != nil

  private static let knownWallet = "0xa4b572ea1b6f734fc88a0a004c5301f8dad54d60"

  private func makeClient() -> LiveBlockscoutClient {
    // Blockscout public instances publish no hard rate limit; 2 req/s is a
    // conservative, polite ceiling for a 3-chain smoke test.
    LiveBlockscoutClient(rateLimiter: RateLimiter(permitsPerSecond: 2))
  }

  @Test(
    "nativeTransactions returns non-empty 0x-hashed results per supported chain",
    .enabled(if: liveNetworkEnabled, "Set MOOLAH_LIVE_NETWORK_TESTS=1 to run live tests"),
    arguments: [ChainConfig.ethereum, ChainConfig.optimism, ChainConfig.base])
  func nativeTransactionsDecodeFromLiveEndpoint(chain: ChainConfig) async throws {
    let client = makeClient()
    let txs = try await client.nativeTransactions(
      chain: chain, walletAddress: Self.knownWallet, fromBlock: 0)
    #expect(!txs.isEmpty, "Expected ≥1 tx from the known-active wallet on chain \(chain.chainId)")
    #expect(txs.map(\.hash).allSatisfy { $0.hasPrefix("0x") }, "All hashes should be 0x-prefixed")
  }
}
