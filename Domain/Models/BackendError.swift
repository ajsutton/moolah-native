/// Errors that any backend implementation may throw.
enum BackendError: Error, Sendable {
  case unauthenticated
  case serverError(Int)
  case networkUnavailable
}
