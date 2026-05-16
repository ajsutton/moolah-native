import Foundation

/// Per-account read-only-token storage seam. The production conformer is
/// `ExchangeTokenStore` (keychain); test code injects a save-throwing
/// double so `ExchangeAccountCreationLogic`'s rollback path can be
/// exercised without keychain entitlements.
protocol ExchangeTokenStoring: Sendable {
  func save(token: String, for accountId: UUID) throws
  func token(for accountId: UUID) throws -> String?
  func delete(for accountId: UUID)
}
