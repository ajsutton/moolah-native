import Foundation
import Testing

@testable import Moolah

@Suite("HTTPRetryClassifier")
struct HTTPRetryClassifierTests {
  @Test(
    arguments: [
      URLError.timedOut, .networkConnectionLost, .cannotConnectToHost,
      .dnsLookupFailed, .notConnectedToInternet,
    ])
  func transientTransportErrorRetriesWhenIdempotent(_ code: URLError.Code) {
    #expect(
      HTTPRetryClassifier.decision(for: URLError(code), idempotent: true)
        == .retryAfterBackoff)
  }

  @Test
  func transientTransportErrorsDoNotRetryWhenNotIdempotent() {
    for code in [URLError.timedOut, .networkConnectionLost] {
      let decision = HTTPRetryClassifier.decision(
        for: URLError(code), idempotent: false)
      #expect(decision == .doNotRetry)
    }
  }

  @Test
  func retrySignalIgnoresIdempotency() {
    #expect(
      HTTPRetryClassifier.decision(
        for: HTTPRetrySignal(retryAfter: nil), idempotent: false)
        == .retryAfterBackoff)
    #expect(
      HTTPRetryClassifier.decision(
        for: HTTPRetrySignal(retryAfter: 9), idempotent: false)
        == .retryAfter(9))
  }

  @Test
  func swiftCancellationErrorNeverRetries() {
    #expect(
      HTTPRetryClassifier.decision(for: CancellationError(), idempotent: true)
        == .doNotRetry)
  }

  @Test
  func urlErrorCancelledNeverRetries() {
    #expect(
      HTTPRetryClassifier.decision(for: URLError(.cancelled), idempotent: true)
        == .doNotRetry)
  }

  @Test
  func retrySignalWithoutDelayUsesBackoff() {
    #expect(
      HTTPRetryClassifier.decision(
        for: HTTPRetrySignal(retryAfter: nil), idempotent: true)
        == .retryAfterBackoff)
  }

  @Test
  func retrySignalWithDelayHonorsServerDelay() {
    #expect(
      HTTPRetryClassifier.decision(
        for: HTTPRetrySignal(retryAfter: 12), idempotent: true)
        == .retryAfter(12))
  }

  @Test
  func unknownErrorsDoNotRetry() {
    struct Other: Error {}
    #expect(
      HTTPRetryClassifier.decision(for: Other(), idempotent: true)
        == .doNotRetry)
  }

  @Test
  func nonTransientURLErrorDoesNotRetry() {
    #expect(
      HTTPRetryClassifier.decision(
        for: URLError(.badServerResponse), idempotent: true) == .doNotRetry)
  }
}
