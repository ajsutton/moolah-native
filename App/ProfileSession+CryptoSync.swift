// App/ProfileSession+CryptoSync.swift
import Foundation
import OSLog

extension ProfileSession {
  /// Returns the live Alchemy API key from the keychain, or `nil` when no
  /// key is configured. Stage 9 ships only the read accessor — Stage 11
  /// owns the settings UI for storing the key. Service / account
  /// strings match `plans/2026-05-05-crypto-wallet-import-design.md`
  /// §"API key management" so the eventual write side targets the same
  /// keychain entry.
  static func resolveAlchemyApiKey() -> String? {
    let store = KeychainStore(
      service: "com.moolah.api-keys", account: "alchemy", synchronizable: true)
    return try? store.restoreString()
  }

  /// Output of `makeCryptoSyncWiring`. The discovery actor is plumbed
  /// out alongside the store so the Stage 11 Discovered Tokens inbox
  /// can drive `reResolve(_:chain:)` on the same actor instance the
  /// sync engine uses — this preserves the in-flight coalescer's
  /// "one round-trip per `(chainId, contractAddress)`" guarantee
  /// across the manual + automatic re-resolution paths.
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
    let apiKey = resolveAlchemyApiKey() ?? ""
    let alchemy: any AlchemyClient = LiveAlchemyClient(
      apiKey: apiKey, rateLimiter: rateLimiter)
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
