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

  private func request() -> URLRequest {
    URLRequest(url: URL(string: "https://example.com/probe") ?? Self.stubURL)
  }

  // MARK: - 2xx success

  @Test
  func twoHundredReturnsDataAndKeepsGateOpen() async throws {
    Stub.reset()
    Stub.handler = { _ in (self.httpResponse(statusCode: 200), Data("OK".utf8)) }

    let session = makeSession()
    let gate = RateLimitGate()

    let (data, _) = try await session.dataRespectingRateLimit(for: request(), gate: gate)
    #expect(data == Data("OK".utf8))

    // Gate still open — second call goes through.
    Stub.handler = { _ in (self.httpResponse(statusCode: 200), Data()) }
    _ = try await session.dataRespectingRateLimit(for: request(), gate: gate)
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

    await #expect(throws: RateLimitGateError.self) {
      try await session.dataRespectingRateLimit(for: self.request(), gate: gate)
    }

    // Subsequent call must fail fast — without hitting the network.
    let countBefore = Stub.capturedRequestCount()
    await #expect(throws: RateLimitGateError.self) {
      try await session.dataRespectingRateLimit(for: self.request(), gate: gate)
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

    await #expect(throws: RateLimitGateError.self) {
      try await session.dataRespectingRateLimit(for: self.request(), gate: gate)
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

    await #expect(throws: RateLimitGateError.self) {
      try await session.dataRespectingRateLimit(for: self.request(), gate: gate)
    }
  }

  @Test
  func fiveOhThreeWithoutRetryAfterDoesNotTripGate() async throws {
    Stub.reset()
    Stub.handler = { _ in (self.httpResponse(statusCode: 503), Data()) }

    let session = makeSession()
    let gate = RateLimitGate()

    // Helper passes through — caller's own status check throws their
    // existing transport error. Here we just verify the gate stays open.
    let (_, response) = try await session.dataRespectingRateLimit(
      for: request(), gate: gate)
    #expect((response as? HTTPURLResponse)?.statusCode == 503)

    // Gate still open — second call gets through to the stub.
    let countBefore = Stub.capturedRequestCount()
    Stub.handler = { _ in (self.httpResponse(statusCode: 200), Data()) }
    _ = try await session.dataRespectingRateLimit(for: request(), gate: gate)
    #expect(Stub.capturedRequestCount() == countBefore + 1)
  }

  // MARK: - Pass-through for other non-2xx

  @Test
  func nonRateLimitErrorPassesThrough() async throws {
    Stub.reset()
    Stub.handler = { _ in (self.httpResponse(statusCode: 500), Data()) }

    let session = makeSession()
    let gate = RateLimitGate()

    let (_, response) = try await session.dataRespectingRateLimit(
      for: request(), gate: gate)
    #expect((response as? HTTPURLResponse)?.statusCode == 500)
  }
}
