// Backends/GRDB/Records/WalletSyncStateRow+Mapping.swift

import Foundation

extension WalletSyncStateRow {
  /// Builds a row from a domain `WalletSyncState`. Throws if the
  /// structured `WalletSyncError` cannot be JSON-encoded — extremely
  /// unlikely, since the error type only carries `Codable` primitives,
  /// but we surface it rather than swallow.
  init(state: WalletSyncState) throws {
    self.accountId = state.id
    self.lastSyncedBlockNumber = Int64(state.lastSyncedBlockNumber)
    self.lastSyncedAt = state.lastSyncedAt
    if let error = state.lastError {
      let data = try JSONEncoder().encode(error)
      // JSONEncoder always produces valid UTF-8; throw if it ever doesn't
      // rather than silently swap to an empty string.
      guard let json = String(bytes: data, encoding: .utf8) else {
        throw BackendError.dataCorrupted(
          "WalletSyncError JSON encoding produced invalid UTF-8")
      }
      self.lastErrorJson = json
    } else {
      self.lastErrorJson = nil
    }
  }

  /// Reconstructs the domain `WalletSyncState` from this row. Throws
  /// `BackendError.dataCorrupted` when the JSON payload exists but
  /// cannot be decoded as `WalletSyncError` — should never happen in
  /// practice (the column has a `json_valid` CHECK and we only ever
  /// write encoded `WalletSyncError`), but the throw beats a silent
  /// `nil` swap.
  func toDomain() throws -> WalletSyncState {
    let lastError: WalletSyncError?
    if let json = lastErrorJson {
      do {
        lastError = try JSONDecoder().decode(
          WalletSyncError.self, from: Data(json.utf8))
      } catch {
        throw BackendError.dataCorrupted(
          "wallet_sync_state.last_error_json failed to decode: \(error)")
      }
    } else {
      lastError = nil
    }
    return WalletSyncState(
      id: accountId,
      lastSyncedBlockNumber: UInt64(max(0, lastSyncedBlockNumber)),
      lastSyncedAt: lastSyncedAt,
      lastError: lastError
    )
  }
}
