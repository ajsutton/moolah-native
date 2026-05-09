// Shared/Networking/URLSession+RateLimited.swift
import Foundation
import OSLog

private let rateLimitedFetchLogger = Logger(
  subsystem: "com.moolah.app", category: "RateLimitedFetch")

extension URLSession {
  /// Sends `request` while respecting `gate`. Wraps the standard
  /// `data(for:)` call with a pre-flight gate check and post-flight
  /// rate-limit detection.
  ///
  /// Pre-flight: if the gate is currently in cooldown, throws
  /// `RateLimitGateError.cooldown(until:)` immediately without hitting
  /// the network. This is what stops a price-fetch loop from continuing
  /// to spam an upstream that has already 429ed us.
  ///
  /// Post-flight: classifies the response by status code:
  ///
  /// - `2xx`: records success on the gate and returns `(data, response)`
  ///   so the caller's existing decode path runs.
  /// - `429` (Too Many Requests) or `418` (Binance's "I'm a teapot",
  ///   meaning "you ignored 429 and you're now temporarily banned"):
  ///   trips the gate using `Retry-After` (or exponential backoff
  ///   when the header is absent) and throws
  ///   `RateLimitGateError.cooldown(until:)`.
  /// - `503` (Service Unavailable) **with** a `Retry-After` header:
  ///   trips the gate the same way. A 503 without `Retry-After` is
  ///   treated as a transient server fault and propagated as-is —
  ///   the next caller probes again rather than waiting blindly.
  /// - Any other status: returns `(data, response)` unchanged. The
  ///   caller's existing 2xx check fires its own error (typically
  ///   `URLError(.badServerResponse)`); the gate state is left
  ///   untouched because the error isn't rate-limit-related.
  ///
  /// The non-rate-limit-error pass-through deliberately does **not**
  /// reset the failure counter — the counter only ever increments on a
  /// rate-limit response and only ever resets on a 2xx, so a stretch of
  /// 5xx errors between 429s doesn't reset the exponential backoff
  /// progression.
  ///
  /// The `Retry-After` HTTP-date parser is anchored at `Date()` rather
  /// than the gate's injected clock. The two are independent: the
  /// parser only converts an HTTP-date into a relative-second offset
  /// for the rare HTTP-date `Retry-After`, while the gate uses its own
  /// clock to compute the cooldown deadline from that offset. Real
  /// servers almost universally return delta-seconds, so the parser
  /// branch that consults the clock is exercised in tests but rarely
  /// in production.
  func dataRespectingRateLimit(
    for request: URLRequest,
    gate: RateLimitGate
  ) async throws -> (Data, URLResponse) {
    try await gate.ensureAvailable()
    let (data, response) = try await self.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      return (data, response)
    }
    let retryAfter = http.retryAfterSeconds(now: Date())
    let host = request.url?.host ?? "?"
    switch http.statusCode {
    case 200...299:
      await gate.recordSuccess()
    case 429, 418:
      let deadline = await gate.recordRateLimit(retryAfter: retryAfter)
      rateLimitedFetchLogger.warning(
        """
        Rate-limited (HTTP \(http.statusCode, privacy: .public)) by \
        \(host, privacy: .public); cooldown until \
        \(deadline.timeIntervalSince1970, privacy: .public)
        """
      )
      throw RateLimitGateError.cooldown(until: deadline)
    case 503 where retryAfter != nil:
      let deadline = await gate.recordRateLimit(retryAfter: retryAfter)
      rateLimitedFetchLogger.warning(
        """
        503 with Retry-After from \(host, privacy: .public); \
        cooldown until \(deadline.timeIntervalSince1970, privacy: .public)
        """
      )
      throw RateLimitGateError.cooldown(until: deadline)
    default:
      break
    }
    return (data, response)
  }
}
