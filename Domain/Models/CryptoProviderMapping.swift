// Domain/Models/CryptoProviderMapping.swift
import Foundation

/// Maps a crypto instrument to its price provider identifiers.
/// Separated from Instrument because provider IDs are lookup metadata,
/// not financial instrument identity.
struct CryptoProviderMapping: Codable, Sendable, Hashable, Identifiable {
  let instrumentId: String  // Matches Instrument.id, e.g. "1:native", "10:0xabc..."

  let coingeckoId: String?
  let cryptocompareSymbol: String?
  let binanceSymbol: String?

  var id: String { instrumentId }

  /// Built-in presets for common tokens.
  static let builtInPresets: [CryptoProviderMapping] =
    CryptoRegistration.builtInPresets.map(\.mapping)
}
