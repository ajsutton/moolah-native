/// Errors that any backend implementation may throw.
enum BackendError: Error, Sendable, Equatable {
  case unauthenticated
  case serverError(Int)
  case networkUnavailable
}
