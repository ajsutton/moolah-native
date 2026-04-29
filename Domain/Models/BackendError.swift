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
  /// Thrown when on-disk data fails a domain invariant the backend expects
  /// to hold — e.g. an enum column carrying a raw value the compiled enum
  /// doesn't know. Indicates either a forward-incompatible schema or
  /// corruption; surfacing it as an error stops the read rather than
  /// silently misclassifying the row.
  case dataCorrupted(String)
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
    case .dataCorrupted:
      return "Your data appears to be corrupted or was written by a newer version of the app."
    }
  }
}

extension Error {
  var userMessage: String {
    (self as? BackendError)?.userMessage ?? "Operation failed: \(localizedDescription)"
  }
}
