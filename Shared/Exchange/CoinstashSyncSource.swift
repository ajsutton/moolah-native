import Foundation
import OSLog

/// `AccountSyncSource` for Coinstash exchange accounts. Resolves the
/// per-account token, fetches via `CoinstashClient`, and builds
/// candidates. Maps provider errors into the shared `WalletSyncError`
/// model so `SyncedAccountStore` stays provider-agnostic. A future
/// exchange gets its own `<Provider>SyncSource` — this one handles
/// `.coinstash` only.
struct CoinstashSyncSource: AccountSyncSource, Sendable {
  private let tokenStore: ExchangeTokenStore
  private let client: any ExchangeClient
  private let engine: ExchangeSyncEngine
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "CoinstashSyncSource")

  init(
    tokenStore: ExchangeTokenStore,
    client: any ExchangeClient,
    engine: ExchangeSyncEngine
  ) {
    self.tokenStore = tokenStore
    self.client = client
    self.engine = engine
  }

  // Concrete provider check (not `!= nil`): with a second exchange's
  // source registered, both must not claim the same account.
  func handles(_ account: Account) -> Bool {
    account.type == .exchange && account.exchangeProvider == .coinstash
  }

  func build(account: Account) async throws -> WalletSyncBuildResult {
    // The Security-framework keychain read is synchronous, on the build
    // task. The token is per-account (not shared) so this is the natural call
    // site; matches the existing Alchemy-key per-request keychain read
    // pattern. Distinguish a genuine "no token" (→ missingApiKey,
    // actionable) from a transient keychain failure (e.g. device locked
    // → treat as network) so the user isn't wrongly told to re-enter a
    // token that exists.
    let token: String?
    do {
      token = try tokenStore.token(for: account.id)
    } catch {
      Self.logger.error(
        "Keychain read failed for \(account.id, privacy: .public): \(error, privacy: .public)")
      throw WalletSyncError.network(
        underlyingDescription: "Keychain read failed: \(error)")
    }
    guard let token, !token.isEmpty else {
      throw WalletSyncError.missingApiKey
    }
    do {
      let imported = try await client.fetchTransactions(token: token)
      return try await engine.build(account: account, imported: imported)
    } catch ExchangeClientError.unauthorized {
      throw WalletSyncError.invalidApiKey
    } catch let error as ExchangeClientError {
      throw WalletSyncError.network(underlyingDescription: String(describing: error))
    }
  }
}
