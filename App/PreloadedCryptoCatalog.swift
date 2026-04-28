import Foundation

/// In-memory `CoinGeckoCatalog` containing a single hard-coded entry.
/// Returned from `UITestSeedCryptoOverrides.overrides(for:)` for seeds that
/// need a deterministic catalogue. `refreshIfStale()` is a no-op so no
/// network access happens during the UI-testing launch.
struct PreloadedCryptoCatalog: CoinGeckoCatalog, Sendable {
  let entries: [CatalogEntry]

  func search(query: String, limit: Int) async -> [CatalogEntry] {
    let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
    if trimmed.isEmpty { return Array(entries.prefix(limit)) }
    let matches = entries.filter { entry in
      entry.coingeckoId.lowercased().contains(trimmed)
        || entry.symbol.lowercased().contains(trimmed)
        || entry.name.lowercased().contains(trimmed)
    }
    return Array(matches.prefix(limit))
  }

  func refreshIfStale() async {}
}

extension PreloadedCryptoCatalog {
  /// The catalogue snapshot installed for the `.cryptoCatalogPreloaded`
  /// seed: a single coin (Uniswap, ETH chainId 1) so the picker has
  /// exactly one match for the search prefix `"uni"`.
  static let cryptoCatalogPreloaded = PreloadedCryptoCatalog(
    entries: [
      CatalogEntry(
        coingeckoId: UITestFixtures.CryptoCatalogPreloaded.coingeckoId,
        symbol: UITestFixtures.CryptoCatalogPreloaded.symbol,
        name: UITestFixtures.CryptoCatalogPreloaded.name,
        platforms: [
          PlatformBinding(
            slug: UITestFixtures.CryptoCatalogPreloaded.chainSlug,
            chainId: UITestFixtures.CryptoCatalogPreloaded.chainId,
            contractAddress: UITestFixtures.CryptoCatalogPreloaded.contractAddress
          )
        ]
      )
    ]
  )
}
