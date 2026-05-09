// Features/Settings/SharedRegistryStore.swift

import Foundation
import OSLog

/// App-level shared store of the registry data. Replaces the data side
/// of the per-session `CryptoTokenStore` so spam decisions, discovered-
/// token resolutions, provider mappings, and `registrationsVersion`
/// changes are visible to every profile session at once.
///
/// **Responsibility split.** Owns the registry-data fields
/// (`registrations`, `instruments`, `providerMappings`,
/// `registrationsVersion`) and the methods that mutate the shared
/// registry (`setStatus`, `removeRegistration`, `loadRegistrations`).
/// Per-session UI state — `isLoading`, `error`, `onRegistrationsChanged`
/// — lives in the per-session `SettingsCryptoStore` (introduced
/// alongside this type) and on existing per-session stores like
/// `InvestmentStore`.
///
/// The shared store does **not** carry an `error` field. Mutation
/// methods throw to the caller; the per-session wrapper catches and
/// surfaces errors locally so one session's transient error doesn't
/// leak onto every Settings screen.
///
/// **Subscription lifetime.** Subscribes once to
/// `registry.observeChanges()` for the lifetime of the store; the
/// observation `Task` is started in `init` and cancelled in `deinit`.
/// `[weak self]` is required to break the retain cycle the stored
/// task would otherwise hold.
///
/// See `plans/2026-05-09-shared-instrument-registry-design.md` and
/// `plans/2026-05-09-shared-instrument-registry-plan.md` (Task 3).
@MainActor
@Observable
final class SharedRegistryStore {
  private(set) var registrations: [CryptoRegistration] = []
  private(set) var instruments: [Instrument] = []
  private(set) var providerMappings: [String: CryptoProviderMapping] = [:]

  /// Monotonic counter bumped after every successful registry mutation.
  /// Views that derive per-account valued positions pin a `.task(id:)`
  /// against this so a `.spam` flip in preferences re-fires the
  /// per-row valuator without the user having to navigate away.
  /// Issue #790.
  private(set) var registrationsVersion: Int = 0

  /// Subset of `registrations` with `pricingStatus == .unpriced`.
  /// Drives the Discovered Tokens inbox row count and the sidebar
  /// badge.
  var unpricedRegistrations: [CryptoRegistration] {
    registrations.filter { $0.pricingStatus == .unpriced }
  }

  /// Convenience for the sidebar / preferences badge — number of
  /// unresolved tokens awaiting user attention.
  var unpricedCount: Int { unpricedRegistrations.count }

  /// Subset of `registrations` with `pricingStatus == .spam`. Drives
  /// the Spam tokens management list.
  var spamRegistrations: [CryptoRegistration] {
    registrations.filter { $0.pricingStatus == .spam }
  }

  private let registry: any InstrumentRegistryRepository
  private let cryptoPriceService: CryptoPriceService
  private let conversionService: any InstrumentConversionService
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "SharedRegistryStore")
  private var observationTask: Task<Void, Never>?

  init(
    registry: any InstrumentRegistryRepository,
    cryptoPriceService: CryptoPriceService,
    conversionService: any InstrumentConversionService
  ) {
    self.registry = registry
    self.cryptoPriceService = cryptoPriceService
    self.conversionService = conversionService

    let stream = registry.observeChanges()
    self.observationTask = Task { @MainActor [weak self] in
      for await _ in stream {
        await self?.loadRegistrations()
      }
    }
  }

  deinit {
    // Swift 6 makes `deinit` nonisolated; reading the `@MainActor`-
    // isolated `observationTask` requires `MainActor.assumeIsolated`.
    // The store is owned by main-actor code (the `SharedInstrumentScope`
    // holder), so the assumption holds in practice.
    MainActor.assumeIsolated {
      observationTask?.cancel()
    }
  }

  // MARK: - Reads

  /// Reloads `registrations`, `instruments`, and `providerMappings`
  /// from the registry. Fired automatically by the observation task on
  /// every registry mutation; callers may also invoke directly to
  /// force a refresh.
  ///
  /// Errors are logged via `os.Logger`; the previous data is left in
  /// place. Per-session UI surfaces invoke this through
  /// `SettingsCryptoStore` which converts thrown errors into UI
  /// state — this method's call from the observation task has no UI
  /// caller and intentionally does not propagate.
  func loadRegistrations() async {
    do {
      let loaded = try await registry.allCryptoRegistrations()
      registrations = loaded
      instruments = loaded.map(\.instrument)
      providerMappings = Dictionary(
        loaded.map { ($0.mapping.instrumentId, $0.mapping) },
        uniquingKeysWith: { _, last in last })
    } catch {
      logger.error(
        "Failed to load crypto registrations: \(error, privacy: .public)")
    }
  }

  // MARK: - Mutations

  /// Removes a registration and purges its cached price rows. Throws
  /// on registry failure; callers in the per-session UI surface should
  /// catch and present the error.
  func removeRegistration(_ registration: CryptoRegistration) async throws {
    try await registry.remove(id: registration.id)
    await cryptoPriceService.purgeCache(instrumentId: registration.id)
    registrations.removeAll { $0.id == registration.id }
    instruments.removeAll { $0.id == registration.id }
    providerMappings.removeValue(forKey: registration.id)
    registrationsVersion &+= 1
  }

  /// Convenience overload — removes the registration backing an
  /// instrument by id.
  func removeInstrument(_ instrument: Instrument) async throws {
    guard
      let registration = registrations.first(where: {
        $0.instrument.id == instrument.id
      })
    else { return }
    try await removeRegistration(registration)
  }

  /// Persists a new `pricingStatus` for an existing registration and
  /// invalidates any cached conversion derived from the instrument so
  /// the next aggregation reads fresh data. Throws on registry
  /// failure; the local in-memory `registrations` list is left
  /// untouched on failure (the next observation tick will reload from
  /// the registry).
  func setStatus(
    _ status: TokenPricingStatus,
    for registration: CryptoRegistration
  ) async throws {
    var updated = registration
    updated.pricingStatus = status
    try await registry.update(updated)
    await conversionService.invalidateCache(for: registration.instrument)
    if let index = registrations.firstIndex(where: { $0.id == registration.id }) {
      registrations[index] = updated
    }
    registrationsVersion &+= 1
  }
}
