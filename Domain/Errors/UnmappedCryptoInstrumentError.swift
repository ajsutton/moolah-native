import Foundation

/// Thrown by `ensureInstrument` when a write references a crypto instrument
/// that has no price-provider mapping registered. Indicates a programmer error —
/// the UI should have routed the user through `InstrumentPickerStore.resolve(_:)`
/// (or the Add Token flow) so the mapping is created before the write is attempted.
struct UnmappedCryptoInstrumentError: Error, Equatable, Sendable {
  let instrumentId: String
}

extension UnmappedCryptoInstrumentError: LocalizedError {
  var errorDescription: String? {
    "Crypto instrument \(instrumentId) cannot be saved without a price-provider mapping."
  }
}
