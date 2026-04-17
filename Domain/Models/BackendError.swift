/// Errors that any backend implementation may throw.
enum BackendError: Error, Sendable, Equatable {
  case unauthenticated
  case serverError(Int)
  case networkUnavailable
  case validationFailed(String)
  case notFound(String)
  /// Thrown by single-instrument backends (Remote, moolah) when a write carries
  /// an instrument other than the profile's currency. Indicates a programmer
  /// error — the UI should have gated the write on `Profile.supportsComplexTransactions`.
  case unsupportedInstrument(String)
}

extension BackendError {
  var userMessage: String {
    switch self {
    case .serverError(let statusCode):
      return "Server error (\(statusCode)). Please try again."
    case .networkUnavailable:
      return "Network error. Check your connection."
    case .unauthenticated:
      return "Session expired. Please log in again."
    case .validationFailed(let message):
      return message
    case .notFound(let message):
      return message
    case .unsupportedInstrument(let message):
      return message
    }
  }
}

extension Error {
  var userMessage: String {
    (self as? BackendError)?.userMessage ?? "Operation failed: \(localizedDescription)"
  }
}
