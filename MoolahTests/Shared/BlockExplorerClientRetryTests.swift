import Foundation
import Testing

@testable import Moolah

/// One scripted transport outcome for `BlockscoutRetryStubURLProtocol`.
enum BlockscoutRetryStep: Sendable {
  case fail(URLError.Code)
  case respond(status: Int, body: Data, headers: [String: String])
}

/// Thread-safe FIFO of scripted transport outcomes, recording call count.
final class BlockscoutRetryScript: @unchecked Sendable {
  private let lock = NSLock()
  private var steps: [BlockscoutRetryStep]
  private(set) var calls = 0

  init(_ steps: [BlockscoutRetryStep]) { self.steps = steps }

  func next() -> BlockscoutRetryStep {
    lock.lock()
    defer { lock.unlock() }
    calls += 1
    precondition(
      !steps.isEmpty, "StubURLProtocol called more times than scripted")
    return steps.removeFirst()
  }
}

/// `URLProtocol` stub driven by a `BlockscoutRetryScript`. Each request pops
/// the next scripted step: a transport failure or a synthetic HTTP response.
class BlockscoutRetryStubURLProtocol: URLProtocol {
  nonisolated(unsafe) static var script: BlockscoutRetryScript?

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let script = Self.script, let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.unknown))
      return
    }
    switch script.next() {
    case .fail(let code):
      client?.urlProtocol(self, didFailWithError: URLError(code))
    case let .respond(status, body, headers):
      guard
        let response = HTTPURLResponse(
          url: url, statusCode: status,
          httpVersion: "HTTP/1.1", headerFields: headers)
      else {
        client?.urlProtocol(self, didFailWithError: URLError(.unknown))
        return
      }
      client?.urlProtocol(
        self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: body)
      client?.urlProtocolDidFinishLoading(self)
    }
  }

  override func stopLoading() {}
}

@Suite("LiveBlockscoutClient retry", .serialized)
struct BlockExplorerClientRetryTests {
  private func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [BlockscoutRetryStubURLProtocol.self]
    return URLSession(configuration: config)
  }

  private static let emptyPage = Data(
    #"{"items":[],"next_page_params":null}"#.utf8)

  @Test
  func transientTimeoutIsRetriedThenSucceeds() async throws {
    defer { BlockscoutRetryStubURLProtocol.script = nil }
    let script = BlockscoutRetryScript([
      .fail(.timedOut),
      .respond(status: 200, body: Self.emptyPage, headers: [:]),
    ])
    BlockscoutRetryStubURLProtocol.script = script
    let client = LiveBlockscoutClient(
      session: makeSession(),
      rateLimiter: RateLimiter(permitsPerSecond: 1000),
      retryPolicy: HTTPRetryPolicy(),
      sleeper: { _ in })
    let txs = try await client.nativeTransactions(
      chain: .ethereum, walletAddress: "0xabc", fromBlock: 0)
    #expect(txs.isEmpty)
    #expect(script.calls == 2)
  }

  @Test
  func longRetryAfterFailsCleanly() async throws {
    defer { BlockscoutRetryStubURLProtocol.script = nil }
    let script = BlockscoutRetryScript([
      .respond(status: 429, body: Data(), headers: ["Retry-After": "999"])
    ])
    BlockscoutRetryStubURLProtocol.script = script
    let client = LiveBlockscoutClient(
      session: makeSession(),
      rateLimiter: RateLimiter(permitsPerSecond: 1000),
      retryPolicy: HTTPRetryPolicy(honorsRetryAfterInPlace: true),
      sleeper: { _ in })
    await #expect(throws: WalletSyncError.self) {
      _ = try await client.nativeTransactions(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0)
    }
    #expect(script.calls == 1)
  }

  @Test
  func shortRetryAfterIsWaitedOutThenSucceeds() async throws {
    defer { BlockscoutRetryStubURLProtocol.script = nil }
    let script = BlockscoutRetryScript([
      .respond(status: 429, body: Data(), headers: ["Retry-After": "5"]),
      .respond(status: 200, body: Self.emptyPage, headers: [:]),
    ])
    BlockscoutRetryStubURLProtocol.script = script
    let client = LiveBlockscoutClient(
      session: makeSession(),
      rateLimiter: RateLimiter(permitsPerSecond: 1000),
      retryPolicy: HTTPRetryPolicy(honorsRetryAfterInPlace: true),
      sleeper: { _ in })
    let txs = try await client.nativeTransactions(
      chain: .ethereum, walletAddress: "0xabc", fromBlock: 0)
    #expect(txs.isEmpty)
    #expect(script.calls == 2)
  }

  @Test
  func transientServerErrorIsRetriedThenSucceeds() async throws {
    defer { BlockscoutRetryStubURLProtocol.script = nil }
    let script = BlockscoutRetryScript([
      .respond(status: 500, body: Data(), headers: [:]),
      .respond(status: 200, body: Self.emptyPage, headers: [:]),
    ])
    BlockscoutRetryStubURLProtocol.script = script
    let client = LiveBlockscoutClient(
      session: makeSession(),
      rateLimiter: RateLimiter(permitsPerSecond: 1000),
      retryPolicy: HTTPRetryPolicy(),
      sleeper: { _ in })
    let txs = try await client.nativeTransactions(
      chain: .ethereum, walletAddress: "0xabc", fromBlock: 0)
    #expect(txs.isEmpty)
    #expect(script.calls == 2)
  }

  @Test
  func urlCancellationSurfacesAsCancellationError() async throws {
    defer { BlockscoutRetryStubURLProtocol.script = nil }
    let script = BlockscoutRetryScript([.fail(.cancelled)])
    BlockscoutRetryStubURLProtocol.script = script
    let client = LiveBlockscoutClient(
      session: makeSession(),
      rateLimiter: RateLimiter(permitsPerSecond: 1000),
      retryPolicy: HTTPRetryPolicy(),
      sleeper: { _ in })
    await #expect(throws: CancellationError.self) {
      _ = try await client.nativeTransactions(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0)
    }
    #expect(script.calls == 1)
  }

  @Test
  func exhaustedRateLimitMapsToRateLimited() async throws {
    defer { BlockscoutRetryStubURLProtocol.script = nil }
    let script = BlockscoutRetryScript([
      .respond(status: 429, body: Data(), headers: ["Retry-After": "5"]),
      .respond(status: 429, body: Data(), headers: ["Retry-After": "5"]),
      .respond(status: 429, body: Data(), headers: ["Retry-After": "5"]),
    ])
    BlockscoutRetryStubURLProtocol.script = script
    let client = LiveBlockscoutClient(
      session: makeSession(),
      rateLimiter: RateLimiter(permitsPerSecond: 1000),
      retryPolicy: HTTPRetryPolicy(honorsRetryAfterInPlace: true),
      sleeper: { _ in })
    do {
      _ = try await client.nativeTransactions(
        chain: .ethereum, walletAddress: "0xabc", fromBlock: 0)
      Issue.record("expected a thrown error")
    } catch let error as WalletSyncError {
      guard case .rateLimited = error else {
        Issue.record("expected .rateLimited, got \(error)")
        return
      }
    }
    #expect(script.calls == 3)
  }
}
