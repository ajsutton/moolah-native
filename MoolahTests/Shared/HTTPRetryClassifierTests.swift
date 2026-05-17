import Foundation
import Testing

@testable import Moolah

@Suite("HTTPRetryClassifier")
struct HTTPRetryClassifierTests {
  @Test
  func transientTransportErrorsRetryWhenIdempotent() {
    for code in [
      URLError.timedOut, .networkConnectionLost, .cannotConnectToHost,
      .dnsLookupFailed, .notConnectedToInternet,
    ] {
      let decision = HTTPRetryClassifier.decision(
        for: URLError(code), idempotent: true)
      #expect(decision == .retryAfterBackoff)
    }
  }

  @Test
  func transientTransportErrorsDoNotRetryWhenNotIdempotent() {
    let decision = HTTPRetryClassifier.decision(
      for: URLError(.timedOut), idempotent: false)
    #expect(decision == .doNotRetry)
  }

  @Test
  func cancellationNeverRetries() {
    #expect(
      HTTPRetryClassifier.decision(for: CancellationError(), idempotent: true)
        == .doNotRetry)
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
