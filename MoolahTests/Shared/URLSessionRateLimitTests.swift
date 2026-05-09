// MoolahTests/Shared/URLSessionRateLimitTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("URLSession.dataRespectingRateLimit")
struct URLSessionRateLimitTests {

  // MARK: - Stub plumbing

  /// `URLProtocol` stub local to this suite — the codebase uses
  /// per-suite stubs (see `YahooFinanceClientTests`,
  /// `AlchemyURLProtocolStub`) so the static handler doesn't collide
  /// across files. Mirrors that pattern. Intentionally non-`final` so
  /// SwiftLint's `static_over_final_class` rule does not apply to the
  /// inherited overrides; `URLProtocol` already declares an unavailable
  /// `Sendable` conformance, so the subclass can't add one — the
  /// `nonisolated(unsafe)` static state is what actually keeps Swift 6
  /// strict concurrency happy here.
  class Stub: URLProtocol {
    nonisolated(unsafe) static var handler:
      (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestCount: Int = 0
    private static let lock = NSLock()

    static func reset() {
      lock.lock()
      defer { lock.unlock() }
      handler = nil
      requestCount = 0
    }

    static func incrementRequestCount() {
      lock.lock()
      defer { lock.unlock() }
      requestCount += 1
    }

    static func capturedRequestCount() -> Int {
      lock.lock()
      defer { lock.unlock() }
      return requestCount
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      Self.incrementRequestCount()
      guard let handler = Self.handler else {
        client?.urlProtocol(self, didFailWithError: URLError(.unknown))
        return
      }
      do {
        let (response, data) = try handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
      } catch {
        client?.urlProtocol(self, didFailWithError: error)
      }
    }

    override func stopLoading() {}
  }

  private static let stubURL = URL(fileURLWithPath: "/")

  private func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [Stub.self]
    return URLSession(configuration: config)
  }

  // swiftlint:disable force_unwrapping
  // `HTTPURLResponse(url:statusCode:httpVersion:headerFields:)` only fails on a
  // malformed `httpVersion`, and `"HTTP/1.1"` is a hardcoded literal — so the
  // force-unwrap below is provably safe. CODE_GUIDE §9 permits this in tests.
  private func httpResponse(
    statusCode: Int, headers: [String: String] = [:]
  ) -> HTTPURLResponse {
    HTTPURLResponse(
      url: Self.stubURL,
      statusCode: statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    )!
  }
  // swiftlint:enable force_unwrapping

  private func request(path: String = "/probe") -> URLRequest {
    URLRequest(url: URL(string: "https://example.com\(path)") ?? Self.stubURL)
  }

  // MARK: - 2xx success

  @Test
  func twoHundredReturnsDataAndKeepsGateOpen() async throws {
    Stub.reset()
    Stub.handler = { _ in (self.httpResponse(statusCode: 200), Data("OK".utf8)) }

    let session = makeSession()
    let gate = RateLimitGate()
    let cache = FailedRequestCache()

    let (data, _) = try await session.dataRespectingRateLimit(
      for: request(), gate: gate, failureCache: cache)
    #expect(data == Data("OK".utf8))

    // Gate still open — second call goes through.
    Stub.handler = { _ in (self.httpResponse(statusCode: 200), Data()) }
    _ = try await session.dataRespectingRateLimit(
      for: request(), gate: gate, failureCache: cache)
  }

  // MARK: - 429 trips the gate

  @Test
  func fourTwentyNineTripsGateAndThrowsCooldown() async throws {
    Stub.reset()
    Stub.handler = { _ in
      (self.httpResponse(statusCode: 429, headers: ["Retry-After": "60"]), Data())
    }

    let session = makeSession()
    let gate = RateLimitGate()
    let cache = FailedRequestCache()

    await #expect(throws: RateLimitGateError.self) {
      try await session.dataRespectingRateLimit(
        for: self.request(), gate: gate, failureCache: cache)
    }

    // Subsequent call must fail fast — without hitting the network.
    let countBefore = Stub.capturedRequestCount()
    await #expect(throws: (any Error).self) {
      try await session.dataRespectingRateLimit(
        for: self.request(), gate: gate, failureCache: cache)
    }
    #expect(Stub.capturedRequestCount() == countBefore)
  }

  // MARK: - 418 trips the gate (Binance ban)

  @Test
  func fourEighteenTripsGate() async throws {
    Stub.reset()
    Stub.handler = { _ in (self.httpResponse(statusCode: 418), Data()) }

    let session = makeSession()
    let gate = RateLimitGate()
    let cache = FailedRequestCache()

    await #expect(throws: RateLimitGateError.self) {
      try await session.dataRespectingRateLimit(
        for: self.request(), gate: gate, failureCache: cache)
    }
  }

  // MARK: - 503 with Retry-After trips, without doesn't

  @Test
  func fiveOhThreeWithRetryAfterTripsGate() async throws {
    Stub.reset()
    Stub.handler = { _ in
      (self.httpResponse(statusCode: 503, headers: ["Retry-After": "10"]), Data())
    }

    let session = makeSession()
    let gate = RateLimitGate()
    let cache = FailedRequestCache()

    await #expect(throws: RateLimitGateError.self) {
      try await session.dataRespectingRateLimit(
        for: self.request(), gate: gate, failureCache: cache)
    }
  }

  @Test
  func fiveOhThreeWithoutRetryAfterDoesNotTripGate() async throws {
    Stub.reset()
    Stub.handler = { _ in (self.httpResponse(statusCode: 503), Data()) }

    let session = makeSession()
    let gate = RateLimitGate()
    // Use a fresh cache scoped to this test; the per-URL cache *does*
    // record on a 503-without-Retry-After (it's a failure) so a follow-up
    // to the *same* URL fails fast. To verify the gate stays open we
    // probe a different URL on the second call instead.
    let cache = FailedRequestCache()

    let (_, response) = try await session.dataRespectingRateLimit(
      for: request(path: "/probe-1"), gate: gate, failureCache: cache)
    #expect((response as? HTTPURLResponse)?.statusCode == 503)

    let countBefore = Stub.capturedRequestCount()
    Stub.handler = { _ in (self.httpResponse(statusCode: 200), Data()) }
    _ = try await session.dataRespectingRateLimit(
      for: request(path: "/probe-2"), gate: gate, failureCache: cache)
    #expect(Stub.capturedRequestCount() == countBefore + 1)
  }

  // MARK: - 404 path

  @Test
  func fourOhFourMutesUrlForFailureCacheCooldown() async throws {
    Stub.reset()
    Stub.handler = { _ in (self.httpResponse(statusCode: 404), Data()) }

    let session = makeSession()
    let gate = RateLimitGate()
    let cache = FailedRequestCache()

    // First call: helper passes through (caller's status-code check
    // would normally throw). Cache records the failure as a side effect.
    let (_, response) = try await session.dataRespectingRateLimit(
      for: request(), gate: gate, failureCache: cache)
    #expect((response as? HTTPURLResponse)?.statusCode == 404)

    // Second call to the *same* URL: must fail fast without hitting the
    // network — this is the spam-loop fix.
    let countBefore = Stub.capturedRequestCount()
    await #expect(throws: FailedRequestCacheError.self) {
      try await session.dataRespectingRateLimit(
        for: self.request(), gate: gate, failureCache: cache)
    }
    #expect(Stub.capturedRequestCount() == countBefore)
  }

  @Test
  func fourOhFourDoesNotAffectOtherUrls() async throws {
    Stub.reset()
    Stub.handler = { request in
      let path = request.url?.path ?? ""
      if path.contains("missing") {
        return (self.httpResponse(statusCode: 404), Data())
      }
      return (self.httpResponse(statusCode: 200), Data("OK".utf8))
    }

    let session = makeSession()
    let gate = RateLimitGate()
    let cache = FailedRequestCache()

    // First request 404s and gets muted.
    _ = try await session.dataRespectingRateLimit(
      for: request(path: "/missing"), gate: gate, failureCache: cache)

    // A different URL on the same host must NOT be muted — only the
    // exact failing URL is throttled, so legitimate fetches continue.
    let (data, _) = try await session.dataRespectingRateLimit(
      for: request(path: "/found"), gate: gate, failureCache: cache)
    #expect(data == Data("OK".utf8))
  }

  // MARK: - 5xx path

  @Test
  func fiveHundredAlsoMutesUrl() async throws {
    Stub.reset()
    Stub.handler = { _ in (self.httpResponse(statusCode: 500), Data()) }

    let session = makeSession()
    let gate = RateLimitGate()
    let cache = FailedRequestCache()

    let (_, response) = try await session.dataRespectingRateLimit(
      for: request(), gate: gate, failureCache: cache)
    #expect((response as? HTTPURLResponse)?.statusCode == 500)

    // Same URL repeat — fails fast.
    let countBefore = Stub.capturedRequestCount()
    await #expect(throws: FailedRequestCacheError.self) {
      try await session.dataRespectingRateLimit(
        for: self.request(), gate: gate, failureCache: cache)
    }
    #expect(Stub.capturedRequestCount() == countBefore)
  }

  // MARK: - Transport-error path

  @Test
  func transportErrorMutesUrl() async throws {
    Stub.reset()
    Stub.handler = { _ in throw URLError(.notConnectedToInternet) }

    let session = makeSession()
    let gate = RateLimitGate()
    let cache = FailedRequestCache()

    await #expect(throws: (any Error).self) {
      try await session.dataRespectingRateLimit(
        for: self.request(), gate: gate, failureCache: cache)
    }

    // Same URL repeated — fails fast from the cache, no second network hit.
    let countBefore = Stub.capturedRequestCount()
    await #expect(throws: FailedRequestCacheError.self) {
      try await session.dataRespectingRateLimit(
        for: self.request(), gate: gate, failureCache: cache)
    }
    #expect(Stub.capturedRequestCount() == countBefore)
  }

  @Test
  func cancellationDoesNotMuteUrl() async throws {
    Stub.reset()
    Stub.handler = { _ in throw URLError(.cancelled) }

    let session = makeSession()
    let gate = RateLimitGate()
    let cache = FailedRequestCache()

    await #expect(throws: (any Error).self) {
      try await session.dataRespectingRateLimit(
        for: self.request(), gate: gate, failureCache: cache)
    }

    // Cancellation is user intent, not a real failure — the URL must
    // remain available so a subsequent retry isn't blocked.
    try await cache.ensureAvailable(for: "https://example.com/probe")
  }

  // MARK: - Success after a failure clears the URL

  @Test
  func twoHundredAfterFailureClearsTheUrl() async throws {
    Stub.reset()
    Stub.handler = { _ in (self.httpResponse(statusCode: 404), Data()) }

    let session = makeSession()
    let gate = RateLimitGate()
    let cache = FailedRequestCache()

    _ = try await session.dataRespectingRateLimit(
      for: request(), gate: gate, failureCache: cache)

    // Manually clear (simulating a successful retry after the cooldown
    // expires) — verifies the path the helper itself takes on a 200.
    await cache.recordSuccess(for: "https://example.com/probe")
    try await cache.ensureAvailable(for: "https://example.com/probe")
  }
}
