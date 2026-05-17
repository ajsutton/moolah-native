// Domain/Models/SyncProvider.swift
import Foundation

/// Identifies which external data provider produced a sync failure, so
/// `WalletSyncError` can attribute the error to its source. String-backed
/// so it round-trips as a stable token inside the persisted
/// `WalletSyncState.lastError` JSON. Per-device only — not a synced
/// record, so adding a case does not touch `DataFormatVersion`.
enum SyncProvider: String, Codable, Sendable, Hashable, CaseIterable {
  case alchemy
  case blockExplorer
  case coinstash
  case coinGecko
  case cryptoCompare
  case binance

  /// User-facing brand name shown in the synced-account error caption.
  /// `.blockExplorer` is "Blockscout" — the codebase already surfaces the
  /// concrete brand "Alchemy" in captions, so this stays consistent.
  var displayName: String {
    switch self {
    case .alchemy: return "Alchemy"
    case .blockExplorer: return "Blockscout"
    case .coinstash: return "Coinstash"
    case .coinGecko: return "CoinGecko"
    case .cryptoCompare: return "CryptoCompare"
    case .binance: return "Binance"
    }
  }
}
