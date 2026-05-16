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
      service: KeychainServices.apiKeys, account: "alchemy", synchronizable: true)
    return try? store.restoreString()
  }

  /// Output of `makeCryptoSyncWiring`. The discovery actor is plumbed
  /// out alongside the store so the Discovered Tokens inbox can drive
  /// `reResolve(_:chain:)` on the same actor instance the sync engine
  /// uses — this preserves the in-flight coalescer's "one round-trip
  /// per `(chainId, contractAddress)`" guarantee across the manual +
  /// automatic re-resolution paths.
  struct CryptoSyncWiring {
    let store: SyncedAccountStore
    let discovery: CryptoTokenDiscoveryService
  }

  /// Builds the `SyncedAccountStore` (and exposes the underlying
  /// `CryptoTokenDiscoveryService`) for a profile, registering the
  /// wallet + Coinstash sync sources. Returns `nil` when the profile
  /// has no `instrumentRegistry` (preview / degraded launches); the
  /// auto-import feature is unavailable in that mode.
  ///
  /// Live wiring uses:
  ///
  /// - `RateLimiter(permitsPerSecond: 25)` matching Alchemy's free-tier
  ///   ceiling (design §"Concurrency model").
  /// - `RateLimiter(permitsPerSecond: 5)` for Blockscout public
  ///   unauthenticated tier (~5 req/s per IP).
  /// - `LiveAlchemyClient` — same shape as `Backends/CoinGecko/CoinGeckoClient`.
  /// - `LiveBlockscoutClient` — authoritative native + internal ETH index.
  /// - `CryptoTokenDiscoveryService` — actor-coalesced registry resolver.
  /// - `WalletSyncEngine` — Stage 6's read-only build orchestrator.
  /// - `WalletApplyEngine` — `@MainActor` apply pass with the shipping
  ///   `NoOpWalletImportRulesEngine`; the richer rules engine is not yet
  ///   wired.
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
    cryptoPriceService: CryptoPriceService,
    profileInstrument: Instrument
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
    // Blockscout public unauthenticated tier: ~5 req/s per IP.
    let blockscoutRateLimiter = RateLimiter(permitsPerSecond: 5)
    let blockExplorer: any BlockExplorerClient = LiveBlockscoutClient(
      rateLimiter: blockscoutRateLimiter)
    let walletSyncEngine = WalletSyncEngine(
      alchemy: alchemy,
      blockExplorer: blockExplorer,
      discovery: discovery,
      walletSyncState: backend.walletSyncState,
      importOriginFactory: importOriginFactory)
    let walletApplyEngine = WalletApplyEngine(
      transactions: backend.transactions,
      walletSyncState: backend.walletSyncState,
      importRules: NoOpWalletImportRulesEngine())
    // Provider-neutral sources. The store asks each `handles(_:)` which
    // accounts it can sync — it never branches on `account.type`.
    // Future exchanges append their own `<Provider>SyncSource` here.
    let walletSource = WalletSyncSource(engine: walletSyncEngine)
    let coinstashSource = CoinstashSyncSource(
      tokenStore: ExchangeTokenStore(synchronizable: true),
      client: CoinstashClient(),
      engine: ExchangeSyncEngine(
        resolver: ExchangeInstrumentResolver(
          registry: registry,
          // The profile's own currency, NOT a hardcoded `.AUD` — a
          // non-AUD profile would otherwise mis-denominate.
          fiatInstrument: profileInstrument)))
    let store = SyncedAccountStore(
      sources: [walletSource, coinstashSource],
      walletApplyEngine: walletApplyEngine,
      walletSyncState: backend.walletSyncState,
      accounts: backend.accounts)
    return CryptoSyncWiring(store: store, discovery: discovery)
  }
}
