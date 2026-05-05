// MoolahTests/Shared/CryptoImport/LiveAlchemyClientErrorTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("LiveAlchemyClient — error mapping")
struct LiveAlchemyClientErrorTests {
  @Test
  func httpUnauthorizedMapsToInvalidApiKey() async throws {
    let client = AlchemyTestSupport.makeClient { request in
      let response = AlchemyTestSupport.response(for: request, statusCode: 401)
      return (response, Data())
    }
    await #expect(throws: WalletSyncError.invalidApiKey) {
      _ = try await client.getAssetTransfers(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0
      )
    }
  }

  @Test
  func httpForbiddenMapsToInvalidApiKey() async throws {
    let client = AlchemyTestSupport.makeClient { request in
      let response = AlchemyTestSupport.response(for: request, statusCode: 403)
      return (response, Data())
    }
    await #expect(throws: WalletSyncError.invalidApiKey) {
      _ = try await client.getAssetTransfers(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0
      )
    }
  }

  @Test
  func httpTooManyRequestsMapsToRateLimitedWithRetryAfter() async throws {
    let client = AlchemyTestSupport.makeClient { request in
      let response = AlchemyTestSupport.response(
        for: request,
        statusCode: 429,
        headerFields: ["Retry-After": "10"]
      )
      return (response, Data())
    }
    do {
      _ = try await client.getAssetTransfers(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0
      )
      Issue.record("Expected WalletSyncError.rateLimited")
    } catch let WalletSyncError.rateLimited(retryAfter) {
      let date = try #require(retryAfter)
      #expect(date.timeIntervalSinceNow > 5)
      #expect(date.timeIntervalSinceNow < 15)
    }
  }

  @Test
  func httpTooManyRequestsWithoutRetryAfterMapsToRateLimitedWithNilDate() async throws {
    let client = AlchemyTestSupport.makeClient { request in
      let response = AlchemyTestSupport.response(for: request, statusCode: 429)
      return (response, Data())
    }
    do {
      _ = try await client.getAssetTransfers(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0
      )
      Issue.record("Expected WalletSyncError.rateLimited")
    } catch let WalletSyncError.rateLimited(retryAfter) {
      #expect(retryAfter == nil)
    }
  }

  @Test
  func httpServerErrorMapsToNetworkError() async throws {
    let client = AlchemyTestSupport.makeClient { request in
      let response = AlchemyTestSupport.response(for: request, statusCode: 503)
      return (response, Data())
    }
    do {
      _ = try await client.getAssetTransfers(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0
      )
      Issue.record("Expected WalletSyncError.network")
    } catch let WalletSyncError.network(description) {
      #expect(description.contains("503"))
    }
  }

  @Test
  func transportFailureMapsToNetworkError() async throws {
    let client = AlchemyTestSupport.makeClient { _ in
      throw URLError(.notConnectedToInternet)
    }
    do {
      _ = try await client.getAssetTransfers(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0
      )
      Issue.record("Expected WalletSyncError.network")
    } catch let WalletSyncError.network(description) {
      #expect(description.isEmpty == false)
    }
  }

  @Test
  func malformedJSONMapsToProviderMalformedResponse() async throws {
    let client = AlchemyTestSupport.makeClient { request in
      let response = AlchemyTestSupport.okResponse(for: request)
      return (response, Data("not json".utf8))
    }
    await #expect(throws: WalletSyncError.providerMalformedResponse(stage: "getAssetTransfers")) {
      _ = try await client.getAssetTransfers(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0
      )
    }
  }
}
