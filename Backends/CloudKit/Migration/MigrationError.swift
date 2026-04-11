import Foundation

enum MigrationError: Error, Sendable {
  case exportFailed(step: String, underlying: Error)
  case importFailed(underlying: Error)
  case verificationFailed(VerificationResult)
  case iCloudUnavailable
  case unexpected(Error)
}

extension MigrationError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .exportFailed(let step, let underlying):
      return "Failed to export \(step): \(underlying.localizedDescription)"
    case .importFailed(let underlying):
      return "Failed to import data: \(underlying.localizedDescription)"
    case .verificationFailed:
      return "Data verification failed after import"
    case .iCloudUnavailable:
      return "iCloud is not available. Please sign in to iCloud in Settings."
    case .unexpected(let error):
      return "Unexpected error: \(error.localizedDescription)"
    }
  }
}
