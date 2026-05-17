// MoolahTests/Shared/CryptoImport/LiveBlockscoutClientAttributionTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("LiveBlockscoutClient provider attribution")
struct LiveBlockscoutClientAttributionTests {
  private func makeFailingClient() -> LiveBlockscoutClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [BlockscoutURLProtocolStub.self]
    let session = URLSession(configuration: config)
    // Throw a URLError from the stub to force a WalletSyncError.network throw.
    BlockscoutURLProtocolStub.requestHandler = { _ in
      throw URLError(.cannotConnectToHost)
    }
    BlockscoutURLProtocolStub.lastRequest = nil
    return LiveBlockscoutClient(
      session: session, rateLimiter: RateLimiter(permitsPerSecond: 1_000))
  }

  @Test("A network failure from nativeTransactions is attributed to .blockExplorer")
  func nativeTransactionsNetworkErrorIsAttributed() async throws {
    let client = makeFailingClient()
    do {
      _ = try await client.nativeTransactions(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0)
      Issue.record("expected throw")
    } catch let error as WalletSyncError {
      #expect(error.provider == .blockExplorer)
    }
  }

  @Test("A network failure from internalTransactions is attributed to .blockExplorer")
  func internalTransactionsNetworkErrorIsAttributed() async throws {
    let client = makeFailingClient()
    do {
      _ = try await client.internalTransactions(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0)
      Issue.record("expected throw")
    } catch let error as WalletSyncError {
      #expect(error.provider == .blockExplorer)
    }
  }
}
