// Shared/CryptoPriceService+Live.swift

import Foundation

// MARK: - CryptoPriceService live (current) prices

// `currentPrices`: the live / spot endpoint — distinct from the historical daily
// bars handled in `CryptoPriceService.swift`'s `price(for:mapping:on:)`
// path. The result is intentionally not persisted via the cap-at-yesterday
// cache; `prefetchLatest` writes a single best-effort yesterday-tagged row
// and the next forward `dailyPrices` extension overwrites it.

extension CryptoPriceService {
  func currentPrices(for mappings: [CryptoProviderMapping]) async throws -> [String: Decimal] {
    var result: [String: Decimal] = [:]
    for client in clients {
      do {
        let prices = try await client.currentPrices(for: mappings)
        for (id, price) in prices where result[id] == nil {
          result[id] = price
        }
        if result.count == mappings.count { break }
      } catch {
        // Best-effort: try the next client. Log so a silent total miss
        // (all clients failed → empty dict) is diagnosable.
        logger.debug(
          "currentPrices: client \(type(of: client), privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
        )
        continue
      }
    }
    if result.isEmpty && !mappings.isEmpty {
      logger.warning("currentPrices: all clients failed; returning empty result")
    }
    return result
  }
}
