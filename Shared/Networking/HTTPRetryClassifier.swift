import Foundation

/// Maps a thrown error to an `HTTPRetryDecision`. Pure and synchronous so it
/// is trivially unit-testable.
enum HTTPRetryClassifier {
  /// `URLError` codes that represent a transient transport failure worth
  /// retrying on an idempotent request.
  private static let retryableTransportCodes: Set<URLError.Code> = [
    .timedOut, .networkConnectionLost, .cannotConnectToHost,
    .dnsLookupFailed, .notConnectedToInternet,
  ]

  static func decision(
    for error: any Error, idempotent: Bool
  ) -> HTTPRetryDecision {
    // Cancellation is user-driven and never a retry, regardless of method.
    if error is CancellationError { return .doNotRetry }
    if let urlError = error as? URLError, urlError.code == .cancelled {
      return .doNotRetry
    }
    // Explicit retry request from the integration layer.
    if let signal = error as? HTTPRetrySignal {
      if let delay = signal.retryAfter { return .retryAfter(delay) }
      return .retryAfterBackoff
    }
    guard idempotent else { return .doNotRetry }
    if let urlError = error as? URLError,
      retryableTransportCodes.contains(urlError.code)
    {
      return .retryAfterBackoff
    }
    return .doNotRetry
  }
}
