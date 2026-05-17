// Shared/CryptoPriceService+FetchRange.swift

import Foundation

// MARK: - CryptoPriceService range-fetch fallback

// `fetchRange` runs the provider fallback chain
// (CoinGecko → CryptoCompare → Binance) for a date range, tolerating
// per-provider failures and only throwing when every client errored.
// It is `internal` (not `private`) because it is called from
// `prices(for:mapping:in:)` in `CryptoPriceService.swift`; it remains
// actor-isolated.

extension CryptoPriceService {
  func fetchRange(
    instrument: Instrument, mapping: CryptoProviderMapping, from: Date, to: Date
  ) async throws {
    let tokenId = instrument.id
    let symbol = instrument.ticker ?? instrument.name
    var lastError: (any Error)?
    var lastProvider: SyncProvider?
    for client in clients {
      lastProvider = client.syncProvider
      do {
        let fetched = try await client.dailyPrices(for: mapping, in: from...to)
        if !fetched.isEmpty {
          let delta = mergeReturningDelta(
            tokenId: tokenId, symbol: symbol, newPrices: fetched)
          if !delta.isEmpty {
            try await persistDelta(tokenId: tokenId, deltaRecords: delta)
          }
          return
        }
      } catch {
        lastError = error
        continue
      }
    }
    if let error = lastError {
      throw WalletSyncError(
        provider: lastProvider,
        kind: .network(underlyingDescription: String(describing: error)))
    }
  }
}
