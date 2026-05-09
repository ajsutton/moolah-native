// Shared/Networking/URLSession+RateLimited.swift
import Foundation
import OSLog

private let rateLimitedFetchLogger = Logger(
  subsystem: "com.moolah.app", category: "RateLimitedFetch")

extension URLSession {
  /// Sends `request` while respecting `gate` and `failureCache`. Wraps
  /// the standard `data(for:)` call with two pre-flight checks (host
  /// rate-limit, per-URL recent-failure) and post-flight bookkeeping.
  ///
  /// **Pre-flight:**
  ///
  /// - If `gate` is in cooldown, throws
  ///   `RateLimitGateError.cooldown(until:)` immediately. This is what
  ///   stops a price-fetch loop from continuing to spam an upstream
  ///   that has already 429ed us.
  /// - If `failureCache` has a live entry for this request's URL,
  ///   throws `FailedRequestCacheError.cooldown(until:)` immediately.
  ///   This is what stops a hot loop from re-issuing the same failed
  ///   request tens of times per session.
  ///
  /// **Post-flight:** classifies the outcome and records into the
  /// failure cache using the variant that matches the error class —
  /// HTTP failures get a fixed-length cooldown, transport failures
  /// get per-URL exponential backoff (capped at 2 minutes by default).
  ///
  /// - Network call threw (DNS failure, offline, timeout, server hang
  ///   up, etc., except cancellation): records via
  ///   `failureCache.recordTransportFailure(for:)` and rethrows.
  ///   Cancellation propagates without muting — it is user-driven,
  ///   not a real failure.
  /// - Response is `2xx`: records success on both `gate` and
  ///   `failureCache`, returns `(data, response)` for the caller's
  ///   existing decode path.
  /// - Response is `429` / `418`: trips the host-wide gate (via
  ///   `Retry-After` or exponential backoff), records via
  ///   `recordHTTPFailure`, throws `RateLimitGateError.cooldown`.
  /// - Response is `503` with `Retry-After`: trips the gate the same
  ///   way and records via `recordHTTPFailure`. A `503` without
  ///   `Retry-After` doesn't trip the gate (the host as a whole is
  ///   still responding) but still records via `recordHTTPFailure` so
  ///   the next caller doesn't immediately re-probe.
  /// - Any other non-2xx (e.g. `404`, `400`, `500`): records via
  ///   `recordHTTPFailure` and returns `(data, response)` so the
  ///   caller's existing status-check throws its usual error.
  /// - Non-`HTTPURLResponse`: returns `(data, response)` unchanged
  ///   without recording (extremely unlikely for HTTP requests).
  ///
  /// The non-rate-limit-error pass-through deliberately does **not**
  /// reset the gate's failure counter — the counter only ever increments
  /// on a rate-limit response and only ever resets on a 2xx, so a
  /// stretch of 5xx errors between 429s doesn't reset the exponential
  /// backoff progression.
  ///
  /// The `Retry-After` HTTP-date parser is anchored at `Date()` rather
  /// than the gate's injected clock. The two are independent: the
  /// parser only converts an HTTP-date into a relative-second offset
  /// for the rare HTTP-date `Retry-After`, while the gate uses its own
  /// clock to compute the cooldown deadline from that offset.
  func dataRespectingRateLimit(
    for request: URLRequest,
    gate: RateLimitGate,
    failureCache: FailedRequestCache
  ) async throws -> (Data, URLResponse) {
    try await gate.ensureAvailable()
    let cacheKey = request.url?.absoluteString
    if let cacheKey {
      try await failureCache.ensureAvailable(for: cacheKey)
    }
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await self.data(for: request)
    } catch {
      if !Self.isCancellation(error), let cacheKey {
        let deadline = await failureCache.recordTransportFailure(for: cacheKey)
        rateLimitedFetchLogger.notice(
          """
          Transport failure for \(request.url?.host ?? "?", privacy: .public): \
          \(error.localizedDescription, privacy: .public); URL muted \
          until \(deadline.timeIntervalSince1970, privacy: .public)
          """
        )
      }
      throw error
    }
    try await Self.classify(
      response: response,
      request: request,
      cacheKey: cacheKey,
      gate: gate,
      failureCache: failureCache
    )
    return (data, response)
  }

  /// Records the `gate` and `failureCache` side effects for an HTTP
  /// response. Throws `RateLimitGateError.cooldown` for rate-limit
  /// responses; returns normally for everything else (including non-2xx
  /// statuses that don't trip the gate). Extracted from the main
  /// function to keep both inside SwiftLint's `function_body_length`
  /// budget.
  private static func classify(
    response: URLResponse,
    request: URLRequest,
    cacheKey: String?,
    gate: RateLimitGate,
    failureCache: FailedRequestCache
  ) async throws {
    guard let http = response as? HTTPURLResponse else { return }
    let retryAfter = http.retryAfterSeconds(now: Date())
    let host = request.url?.host ?? "?"
    switch http.statusCode {
    case 200...299:
      await gate.recordSuccess()
      if let cacheKey {
        await failureCache.recordSuccess(for: cacheKey)
      }
    case 429, 418:
      try await tripGate(
        outcome: .init(retryAfter: retryAfter, statusCode: http.statusCode, host: host),
        cacheKey: cacheKey,
        gate: gate,
        failureCache: failureCache
      )
    case 503 where retryAfter != nil:
      try await tripGate(
        outcome: .init(retryAfter: retryAfter, statusCode: http.statusCode, host: host),
        cacheKey: cacheKey,
        gate: gate,
        failureCache: failureCache
      )
    default:
      if let cacheKey {
        let deadline = await failureCache.recordHTTPFailure(for: cacheKey)
        rateLimitedFetchLogger.notice(
          """
          Request failed (HTTP \(http.statusCode, privacy: .public)) for \
          \(host, privacy: .public); URL muted until \
          \(deadline.timeIntervalSince1970, privacy: .public)
          """
        )
      }
    }
  }

  /// Bundle of the per-response inputs `tripGate` needs, kept as a
  /// nested struct so the surrounding function stays under SwiftLint's
  /// `function_parameter_count` budget (5).
  private struct RateLimitOutcome {
    let retryAfter: TimeInterval?
    let statusCode: Int
    let host: String
  }

  private static func tripGate(
    outcome: RateLimitOutcome,
    cacheKey: String?,
    gate: RateLimitGate,
    failureCache: FailedRequestCache
  ) async throws {
    let deadline = await gate.recordRateLimit(retryAfter: outcome.retryAfter)
    if let cacheKey {
      await failureCache.recordHTTPFailure(for: cacheKey)
    }
    rateLimitedFetchLogger.warning(
      """
      Rate-limited (HTTP \(outcome.statusCode, privacy: .public)) by \
      \(outcome.host, privacy: .public); cooldown until \
      \(deadline.timeIntervalSince1970, privacy: .public)
      """
    )
    throw RateLimitGateError.cooldown(until: deadline)
  }

  /// `URLSession.data(for:)` throws `URLError(.cancelled)` when the
  /// request is explicitly cancelled, while `Task.cancel()` propagates
  /// `CancellationError` through the `try await`. Neither is a real
  /// network failure — they reflect user intent and shouldn't mute the
  /// URL. Anything else (DNS failure, offline, timeout, server hangup)
  /// counts as a failure for the per-URL cache.
  private static func isCancellation(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    return false
  }
}
