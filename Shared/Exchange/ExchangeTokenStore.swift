import Foundation

/// Per-account keychain storage for an exchange account's read-only access
/// token. Each Moolah account gets its own keychain row keyed by account id,
/// in the same env-scoped `apiKeys` service the Alchemy/CoinGecko keys use.
/// Production uses the iCloud-synced keychain so the token follows the user
/// across devices (the token is a secret and must never enter the DB/CloudKit).
struct ExchangeTokenStore: Sendable {
  private let synchronizable: Bool

  init(synchronizable: Bool = true) {
    self.synchronizable = synchronizable
  }

  private func store(for accountId: UUID) -> KeychainStore {
    KeychainStore(
      service: KeychainServices.apiKeys,
      account: "exchange-token-\(accountId.uuidString)",
      synchronizable: synchronizable)
  }

  func save(token: String, for accountId: UUID) throws {
    try store(for: accountId).saveString(token)
  }

  func token(for accountId: UUID) throws -> String? {
    try store(for: accountId).restoreString()
  }

  func delete(for accountId: UUID) {
    store(for: accountId).clear()
  }
}
