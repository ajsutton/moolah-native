/// Errors that any backend implementation may throw.
enum BackendError: Error, Sendable, Equatable {
  case unauthenticated
  case serverError(Int)
  case networkUnavailable
  case validationFailed(String)
  case notFound(String)
  /// Thrown when a write carries an instrument that isn't allowed for the
  /// target entity (e.g. an earmark whose instrument doesn't match the
  /// containing entity). Indicates a programmer error — the UI should have
  /// rejected the write before reaching the backend.
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
