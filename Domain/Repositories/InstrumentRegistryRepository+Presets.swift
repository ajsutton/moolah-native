// Domain/Repositories/InstrumentRegistryRepository+Presets.swift
import Foundation
import OSLog

extension InstrumentRegistryRepository {
  /// Seed every `CryptoRegistration.builtInPresets` entry that is not
  /// already registered with a provider mapping. Idempotent: presets
  /// whose `cryptoRegistration(byId:)` resolves to a non-nil
  /// registration are skipped — the existing mapping wins.
  ///
  /// Provides the offline-first, no-network path that lets transaction
  /// detail / running-balance / aggregation render correctly the very
  /// first time a profile session reads a crypto leg, without waiting
  /// for wallet sync to fire (issue #791). Per-preset failures are
  /// logged and skipped so a single bad row doesn't block the rest.
  ///
  /// Cancellation propagates immediately. Best-effort otherwise.
  func registerBuiltInPresetsIfMissing() async {
    let logger = Logger(
      subsystem: "com.moolah.app", category: "InstrumentRegistryPresets")
    for preset in CryptoRegistration.builtInPresets {
      do {
        try Task.checkCancellation()
        if try await cryptoRegistration(byId: preset.id) != nil {
          continue
        }
        try await registerCrypto(preset.instrument, mapping: preset.mapping)
      } catch is CancellationError {
        return
      } catch {
        logger.warning(
          """
          registerBuiltInPresetsIfMissing: \(preset.id, privacy: .public): \
          \(error.localizedDescription, privacy: .public)
          """
        )
      }
    }
  }
}
