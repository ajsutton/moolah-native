// Domain/Repositories/InstrumentRegistryRepository.swift
import Foundation

/// The authoritative source of instruments visible to a profile. Stock and
/// crypto instruments are stored in the profile's CloudKit-synced
/// `InstrumentRecord` table; fiat instruments are ambient and synthesized
/// from `Locale.Currency.isoCurrencies`.
protocol InstrumentRegistryRepository: Sendable {
  /// Every instrument visible to the profile: stock + crypto rows from the
  /// database, merged with the ambient fiat ISO list from
  /// `Locale.Currency.isoCurrencies`. De-duplicated by `Instrument.id`
  /// (stored row wins on collision with an ambient fiat entry).
  /// Throws on a backing-store failure (e.g. `ModelContainer` unavailable).
  func all() async throws -> [Instrument]

  /// All registered crypto instruments paired with their provider mappings.
  /// Rows whose three provider-mapping fields are all nil are skipped — they
  /// cannot be priced. (Such rows can arise from an auto-insert via
  /// `ensureInstrument` for a CSV-imported crypto position before the user
  /// has resolved its mapping.)
  /// Throws on a backing-store failure.
  func allCryptoRegistrations() async throws -> [CryptoRegistration]

  /// Registers (or upserts) a crypto instrument with its provider mapping.
  /// Re-registering an id that already exists overwrites the mapping and
  /// mutable metadata fields rather than duplicating the row. Invokes the
  /// implementation's sync-queue hook after a successful write.
  ///
  /// - Precondition: `instrument.kind == .cryptoToken`. Passing any other
  ///   kind is a programmer error and traps.
  func registerCrypto(
    _ instrument: Instrument, mapping: CryptoProviderMapping
  ) async throws

  /// Registers (or upserts) a stock instrument. Stock rows carry no
  /// provider-mapping fields; Yahoo's lookup key is the instrument's own
  /// ticker. Invokes the implementation's sync-queue hook after a
  /// successful write.
  ///
  /// - Precondition: `instrument.kind == .stock`. Passing any other
  ///   kind is a programmer error and traps.
  func registerStock(_ instrument: Instrument) async throws

  /// Removes a registered instrument by id. No-op for fiat ids and for
  /// ids that are not currently registered — does not throw. Invokes the
  /// implementation's sync-queue hook after a successful delete.
  func remove(id: String) async throws

  /// Creates a fresh change-observation stream for a single consumer.
  /// Every mutating call on this repository (`registerCrypto`, `registerStock`,
  /// `remove`) yields a `Void` to every outstanding stream created via this
  /// method. Terminating the returned AsyncStream (consumer cancellation
  /// or break) removes its continuation from the fan-out list.
  ///
  /// After receiving a notification, callers must re-fetch by calling
  /// `all()` or `allCryptoRegistrations()` to obtain the updated snapshot —
  /// the `Void` payload is a signal, not a diff.
  ///
  /// Scope: this stream fires only for *local* mutations on this
  /// repository instance. Remote-change notifications delivered by
  /// `CKSyncEngine` apply to `InstrumentRecord` via `batchUpsertInstruments`
  /// and do NOT fan out through this stream — consumers that must react
  /// to remote changes also subscribe to the existing per-profile
  /// `SyncCoordinator` observer signal.
  ///
  /// `@MainActor`-isolated because the implementation registers the
  /// continuation in a `@MainActor`-confined dictionary synchronously —
  /// hopping via `Task { @MainActor in ... }` would let a mutation fired
  /// immediately after this call miss the event.
  @MainActor
  func observeChanges() -> AsyncStream<Void>
}
