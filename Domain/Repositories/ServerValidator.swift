import Foundation

/// Validates that a URL points to a compatible Moolah server.
protocol ServerValidator: Sendable {
  /// Checks the server at the given URL responds correctly.
  /// Throws `BackendError.validationFailed` with a user-facing message on failure.
  func validate(url: URL) async throws
}
