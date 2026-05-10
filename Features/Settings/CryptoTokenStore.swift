// Features/Settings/CryptoTokenStore.swift
import Foundation
import OSLog

@MainActor
@Observable
final class CryptoTokenStore {
  private(set) var registrations: [CryptoRegistration] = []
  private(set) var instruments: [Instrument] = []
  private(set) var providerMappings: [String: CryptoProviderMapping] = [:]

  private(set) var isLoading = false

  private(set) var error: String?

  /// Fired after a successful registry mutation that may change a
  /// registration's `pricingStatus` or remove a row. Wired by
  /// `ProfileSession` to drive the per-store re-aggregation that
  /// otherwise wouldn't observe registry changes — e.g. so the
  /// `InvestmentStore`'s `valuedPositions` drops a freshly-marked
  /// `.spam` token from the account's position list. Issue #790.
  var onRegistrationsChanged: (@MainActor () -> Void)?

  /// Monotonic version bumped after every successful registry mutation
  /// (`setStatus`, `removeRegistration`). Views that derive per-account
  /// valued positions pin a `.task(id:)` against this so a `.spam` flip
  /// in preferences re-fires the per-row valuator without the user
  /// having to navigate away. Issue #790.
  private(set) var registrationsVersion: Int = 0

  private let registry: any InstrumentRegistryRepository
  private let cryptoPriceService: CryptoPriceService
  private let conversionService: any InstrumentConversionService
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "CryptoTokenStore")

  private let apiKeyStore: KeychainStore

  /// Keychain entry for the Alchemy API key, used by the crypto-wallet
  /// auto-import (Stage 9 onward). Service / account strings match
  /// `plans/2026-05-05-crypto-wallet-import-design.md` §"API key
  /// management" so reads from `ProfileSession+CryptoSync` pick up the
  /// value the settings UI writes here. Production wires this to the
  /// iCloud-synced keychain (`synchronizable: true`); tests inject a
  /// non-synced `KeychainStore` since the test runner cannot write to
  /// the synced keychain in CI.
  private let alchemyKeyStore: KeychainStore

  /// Designated initialiser — accepts the keychain stores explicitly.
  /// Production constructs both stores against the iCloud-synced
  /// keychain at the canonical service / account ids (see the
  /// `convenience init` below). Tests inject non-synchronisable
  /// instances since the macOS test runner cannot write to the synced
  /// keychain. Internal access (not `private`) so tests in the same
  /// module can reach it; the production convenience initialiser stays
  /// the public surface.
  init(
    registry: any InstrumentRegistryRepository,
    cryptoPriceService: CryptoPriceService,
    conversionService: any InstrumentConversionService,
    apiKeyStore: KeychainStore,
    alchemyKeyStore: KeychainStore
  ) {
    self.registry = registry
    self.cryptoPriceService = cryptoPriceService
    self.conversionService = conversionService
    self.apiKeyStore = apiKeyStore
    self.alchemyKeyStore = alchemyKeyStore
  }

  /// Production convenience initialiser — wires both keychain stores
  /// to the iCloud-synced keychain at the canonical service / account
  /// ids. The shape mirrors `ProfileSession.resolveAlchemyApiKey()`'s
  /// keychain coordinates so a write from settings is picked up by
  /// the next sync cycle without further plumbing.
  convenience init(
    registry: any InstrumentRegistryRepository,
    cryptoPriceService: CryptoPriceService,
    conversionService: any InstrumentConversionService
  ) {
    self.init(
      registry: registry,
      cryptoPriceService: cryptoPriceService,
      conversionService: conversionService,
      apiKeyStore: KeychainStore(
        service: "com.moolah.api-keys", account: "coingecko", synchronizable: true),
      alchemyKeyStore: KeychainStore(
        service: "com.moolah.api-keys", account: "alchemy", synchronizable: true)
    )
  }

  // MARK: - Filtered registrations

  /// Subset of `registrations` with `pricingStatus == .unpriced`. Drives
  /// the Discovered Tokens inbox row count + the sidebar badge.
  var unpricedRegistrations: [CryptoRegistration] {
    registrations.filter { $0.pricingStatus == .unpriced }
  }

  /// Convenience for the sidebar / preferences badge — number of
  /// unresolved tokens awaiting user attention.
  var unpricedCount: Int { unpricedRegistrations.count }

  /// Subset of `registrations` with `pricingStatus == .spam`. Drives the
  /// Spam tokens management list.
  var spamRegistrations: [CryptoRegistration] {
    registrations.filter { $0.pricingStatus == .spam }
  }

  /// The instruments of all `.spam`-flagged registrations.
  ///
  /// Derived from `spamRegistrations`; updates automatically whenever
  /// `registrations` changes. Returns an empty set when no registrations
  /// carry `.spam` status.
  var spamInstruments: Set<Instrument> {
    Set(spamRegistrations.map(\.instrument))
  }

  func loadRegistrations() async {
    isLoading = true
    defer { isLoading = false }
    do {
      let loaded = try await registry.allCryptoRegistrations()
      registrations = loaded
      instruments = loaded.map(\.instrument)
      providerMappings = Dictionary(
        loaded.map { ($0.mapping.instrumentId, $0.mapping) },
        uniquingKeysWith: { _, last in last }
      )
      error = nil
    } catch {
      logger.error(
        "Failed to load crypto registrations: \(error, privacy: .public)")
      self.error = error.localizedDescription
    }
  }

  func removeRegistration(_ registration: CryptoRegistration) async {
    do {
      try await registry.remove(id: registration.id)
      await cryptoPriceService.purgeCache(instrumentId: registration.id)
      registrations.removeAll { $0.id == registration.id }
      instruments.removeAll { $0.id == registration.id }
      providerMappings.removeValue(forKey: registration.id)
      registrationsVersion &+= 1
      onRegistrationsChanged?()
    } catch {
      logger.error("Failed to remove registration: \(error, privacy: .public)")
      self.error = error.localizedDescription
    }
  }

  func removeInstrument(_ instrument: Instrument) async {
    guard let registration = registrations.first(where: { $0.instrument.id == instrument.id })
    else { return }
    await removeRegistration(registration)
  }

  /// Persists a new `pricingStatus` for an existing registration and
  /// synchronously invalidates any cached conversion derived from the
  /// instrument so the next aggregation reads fresh data. Used by the
  /// Discovered Tokens inbox + Spam tokens management UI to flip a
  /// registration between `.priced` / `.unpriced` / `.spam`.
  ///
  /// On failure the local in-memory `registrations` list is left
  /// untouched and `error` is set; the caller's view re-renders against
  /// the previous state. Cache invalidation only runs after the registry
  /// write succeeds — we never invalidate on behalf of a write that
  /// didn't happen.
  func setStatus(
    _ status: TokenPricingStatus,
    for registration: CryptoRegistration
  ) async {
    var updated = registration
    updated.pricingStatus = status
    do {
      try await registry.update(updated)
      await conversionService.invalidateCache(for: registration.instrument)
      if let index = registrations.firstIndex(where: { $0.id == registration.id }) {
        registrations[index] = updated
      }
      error = nil
      registrationsVersion &+= 1
      onRegistrationsChanged?()
    } catch {
      logger.error("Failed to set pricing status: \(error, privacy: .public)")
      self.error = error.localizedDescription
    }
  }

  // MARK: - CoinGecko API Key

  var hasApiKey: Bool {
    do {
      return try apiKeyStore.restoreString() != nil
    } catch {
      logger.error("keychain read failed: \(error.localizedDescription)")
      return false
    }
  }

  func saveApiKey(_ key: String) {
    do {
      try apiKeyStore.saveString(key)
    } catch {
      self.error = "Failed to save API key: \(error.localizedDescription)"
    }
  }

  func clearApiKey() {
    apiKeyStore.clear()
  }

  // MARK: - Alchemy API Key
  //
  // The Alchemy key drives the wallet auto-import (Stage 9 onward).
  // `ProfileSession.resolveAlchemyApiKey()` reads from the same
  // `(service, account)` keychain entry, so a write here is picked up
  // by the next sync cycle without further plumbing. Privacy: never
  // logged. Failures surface via the store's `error` string only —
  // the underlying `OSStatus` never appears in `os.Logger`.

  /// `true` when an Alchemy API key is configured in the synced
  /// Keychain. Read on every UI render to drive the status badge —
  /// the keychain read is cheap (~µs) and consulting a cached `Bool`
  /// would require an explicit invalidation hook on save / clear.
  var hasAlchemyApiKey: Bool {
    do {
      return try alchemyKeyStore.restoreString() != nil
    } catch {
      logger.error("keychain read failed: \(error.localizedDescription)")
      return false
    }
  }

  /// Persists the Alchemy API key to the synced Keychain. Sets
  /// `error` (without logging the key) on failure.
  func saveAlchemyApiKey(_ key: String) {
    do {
      try alchemyKeyStore.saveString(key)
    } catch {
      self.error = "Failed to save Alchemy API key: \(error.localizedDescription)"
    }
  }

  /// Removes the Alchemy API key from the synced Keychain. Subsequent
  /// sync cycles will produce `WalletSyncError.missingApiKey` until a
  /// new key is saved.
  func clearAlchemyApiKey() {
    alchemyKeyStore.clear()
  }
}
