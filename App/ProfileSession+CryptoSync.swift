// App/ProfileSession+CryptoSync.swift
import Foundation
import OSLog

extension ProfileSession {
  /// Returns the live Alchemy API key from the keychain, or `nil` when no
  /// key is configured. Read-only here; the settings UI owns the
  /// write side. Service / account strings are pinned to the values
  /// the settings UI writes against so both ends target the same
  /// keychain entry.
  ///
  /// `nonisolated` so it can be called from the `@Sendable` closure that
  /// `LiveAlchemyClient` uses to resolve the key per-request — the work
  /// itself is just a synchronous Keychain read, so it doesn't need
  /// `@MainActor` isolation that the surrounding `ProfileSession`
  /// extension inherits.
  nonisolated static func resolveAlchemyApiKey() -> String? {
    let store = KeychainStore(
      service: "com.moolah.api-keys", account: "alchemy", synchronizable: true)
    return try? store.restoreString()
  }

  /// Output of `makeCryptoSyncWiring`. The discovery actor is plumbed
  /// out alongside the store so the Discovered Tokens inbox can drive
  /// `reResolve(_:chain:)` on the same actor instance the sync engine
  /// uses — this preserves the in-flight coalescer's "one round-trip
  /// per `(chainId, contractAddress)`" guarantee across the manual +
  /// automatic re-resolution paths.
  struct CryptoSyncWiring {
    let store: CryptoSyncStore
    let discovery: CryptoTokenDiscoveryService
  }

  /// Builds the `CryptoSyncStore` (and exposes the underlying
  /// `CryptoTokenDiscoveryService`) for a profile. Returns `nil` when
  /// the profile has no `instrumentRegistry` (preview / degraded
  /// launches); the wallet-import feature is unavailable in that mode.
  ///
  /// Live wiring uses:
  ///
  /// - `RateLimiter(permitsPerSecond: 25)` matching Alchemy's free-tier
  ///   ceiling (design §"Concurrency model").
  /// - `LiveAlchemyClient` — same shape as `Backends/CoinGecko/CoinGeckoClient`.
  /// - `CryptoTokenDiscoveryService` — actor-coalesced registry resolver.
  /// - `WalletSyncEngine` — Stage 6's read-only build orchestrator.
  /// - `WalletApplyEngine` — Stage 7's `@MainActor` apply pass with the
  ///   shipping `NoOpWalletImportRulesEngine`. The richer rules pass
  ///   lands alongside the wallet rules UI in a follow-up.
  ///
  /// The keychain read is best-effort: the live `LiveAlchemyClient` is
  /// constructed even when the key is missing or empty so the build
  /// phase throws a typed `.invalidApiKey` (HTTP 401/403) on the first
  /// account, the store records it, and the user sees a banner asking
  /// them to set the key. This avoids a `nil`-AlchemyClient branch that
  /// would silently skip every crypto account.
  @MainActor
  static func makeCryptoSyncWiring(
    backend: BackendProvider,
    registry: (any InstrumentRegistryRepository)?,
    cryptoPriceService: CryptoPriceService
  ) -> CryptoSyncWiring? {
    guard let registry else { return nil }

    let rateLimiter = RateLimiter(permitsPerSecond: 25)
    // Pass a closure rather than a resolved value so a key added in the
    // settings UI *after* this wiring is built is visible on the next
    // sync cycle, and so the key is never retained on the client itself
    // — it lives only on the local stack frame of each in-flight
    // request.
    let alchemy: any AlchemyClient = LiveAlchemyClient(
      apiKeyProvider: { ProfileSession.resolveAlchemyApiKey() },
      rateLimiter: rateLimiter)
    let discovery = CryptoTokenDiscoveryService(
      registry: registry, resolver: cryptoPriceService, alchemy: alchemy)
    let importOriginFactory: @Sendable (UUID) -> ImportOrigin = { accountId in
      ImportOrigin(
        rawDescription: "wallet:\(accountId.uuidString)",
        rawAmount: 0,
        importedAt: Date(),
        importSessionId: UUID(),
        parserIdentifier: "alchemy-wallet-sync")
    }
    let walletSyncEngine = WalletSyncEngine(
      alchemy: alchemy,
      discovery: discovery,
      walletSyncState: backend.walletSyncState,
      importOriginFactory: importOriginFactory)
    let walletApplyEngine = WalletApplyEngine(
      transactions: backend.transactions,
      walletSyncState: backend.walletSyncState,
      importRules: NoOpWalletImportRulesEngine())
    let store = CryptoSyncStore(
      walletSyncEngine: walletSyncEngine,
      walletApplyEngine: walletApplyEngine,
      walletSyncState: backend.walletSyncState,
      accounts: backend.accounts)
    return CryptoSyncWiring(store: store, discovery: discovery)
  }
}
