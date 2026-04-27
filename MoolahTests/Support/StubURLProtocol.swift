// MoolahTests/Support/StubURLProtocol.swift
import Foundation

/// Process-wide `URLProtocol` stub that dispatches by `"<host>:<path>"` so a
/// single registration can serve multiple endpoints in the same test. Tests
/// install handlers per-test (in `init`) and reset them on teardown.
///
/// Tests construct an ephemeral `URLSession` whose `protocolClasses` lists
/// this stub, so requests stay scoped to the test's session — calling
/// `URLProtocol.registerClass(_:)` is unnecessary and skipped.
///
/// Intentionally non-`final` so SwiftLint's `static_over_final_class` rule
/// doesn't apply to the inherited overrides. `URLProtocol` already declares
/// its own (unavailable) Sendable conformance, so the subclass can't add a
/// new one — `nonisolated(unsafe)` on the static handlers map is what
/// actually keeps Swift 6 strict concurrency happy here.
class StubURLProtocol: URLProtocol {
  /// `nonisolated(unsafe)` because tests are single-threaded with respect to
  /// this map (handlers are installed in `init`, read on the session's
  /// internal queue per request, and cleared in `deinit`). Concurrent
  /// fixture-loading tests use disjoint host/path keys, so there is no
  /// shared mutable state at the test boundary.
  nonisolated(unsafe) static var handlers:
    [String: @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)] = [:]

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, let host = url.host else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let key = "\(host):\(url.path)"
    guard let handler = Self.handlers[key] else {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
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

extension HTTPURLResponse {
  /// Sentinel response URL for stub-built responses; the value is irrelevant
  /// to the assertions because `URLSession` reports the request URL on the
  /// resulting response object regardless. `URL(fileURLWithPath:)` always
  /// returns a non-optional URL, so we get a force-unwrap-free constant.
  private static let stubResponseURL = URL(fileURLWithPath: "/")

  // swiftlint:disable force_unwrapping
  // `HTTPURLResponse(url:statusCode:httpVersion:headerFields:)` only fails on
  // a malformed `httpVersion`, and `"HTTP/1.1"` is a hardcoded literal — so
  // the force-unwraps below are provably safe. The previous
  // `?? HTTPURLResponse()` fallback would have papered over a programmer
  // error rather than handling a real failure mode, so force-unwrap is the
  // honest spelling. CODE_GUIDE §9 explicitly permits this in test code.

  /// Convenience for tests building 200 responses with an `ETag` header.
  static func ok(etag: String) -> HTTPURLResponse {
    HTTPURLResponse(
      url: stubResponseURL,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["ETag": etag, "Content-Type": "application/json"]
    )!
  }

  /// 304 Not Modified for conditional GETs returning no body.
  static func notModified() -> HTTPURLResponse {
    HTTPURLResponse(
      url: stubResponseURL,
      statusCode: 304,
      httpVersion: "HTTP/1.1",
      headerFields: [:]
    )!
  }
  // swiftlint:enable force_unwrapping
}
