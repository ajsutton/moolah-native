import Foundation

/// UI-testing-only overrides for the CoinGecko catalogue and the token
/// resolution client. Consulted from `ProfileSession.makeRegistryWiring`
/// when the process was launched with `--ui-testing` and the active
/// `UITestSeed` requests a deterministic catalogue/resolver instead of
/// the live SQLite-backed snapshot and network resolver.
///
/// The live `SQLiteCoinGeckoCatalog` reads from disk and `refreshIfStale()`
/// can hit the CoinGecko API; `CompositeTokenResolutionClient` always hits
/// the network. Neither is acceptable in a UI test, so seeds that exercise
/// the picker substitute the pair below for a fixed, in-memory snapshot.
@MainActor
enum UITestSeedCryptoOverrides {
  /// Returns the catalogue/resolver pair to use under UI testing for the
  /// given seed, or `nil` to fall through to the production wiring. Any
  /// seed not listed here uses the live wiring (so for example
  /// `tradeBaseline` keeps the SQLite snapshot — the trade tests don't
  /// exercise crypto search).
  static func overrides(
    for seed: UITestSeed
  ) -> (catalog: any CoinGeckoCatalog, resolutionClient: any TokenResolutionClient)? {
    switch seed {
    case .cryptoCatalogPreloaded:
      return (
        catalog: PreloadedCryptoCatalog.cryptoCatalogPreloaded,
        resolutionClient: PreloadedTokenResolutionClient.cryptoCatalogPreloaded
      )
    case .tradeBaseline,
      .welcomeEmpty,
      .welcomeSingleCloudProfile,
      .welcomeMultipleCloudProfiles,
      .welcomeDownloading,
      .sidebarFooterUpToDate,
      .sidebarFooterReceiving,
      .sidebarFooterSending:
      return nil
    }
  }
}

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

/// Deterministic `TokenResolutionClient` used in UI tests. Returns a
/// hard-coded `(coingeckoId, cryptocompareSymbol, binanceSymbol)` triple
/// for the matching `(chainId, contractAddress)` and an empty result
/// otherwise — so a row that doesn't match the seed's expected token is
/// not silently registered.
struct PreloadedTokenResolutionClient: TokenResolutionClient, Sendable {
  let chainId: Int
  let contractAddress: String
  let result: TokenResolutionResult

  func resolve(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async throws -> TokenResolutionResult {
    if chainId == self.chainId,
      let address = contractAddress,
      address.lowercased() == self.contractAddress.lowercased()
    {
      return result
    }
    return TokenResolutionResult()
  }
}

extension PreloadedTokenResolutionClient {
  /// The resolution stub installed for the `.cryptoCatalogPreloaded` seed.
  /// Matches the catalogue's single coin so a tap on the Uniswap row
  /// resolves with all three provider IDs populated and registration
  /// succeeds.
  static let cryptoCatalogPreloaded = PreloadedTokenResolutionClient(
    chainId: UITestFixtures.CryptoCatalogPreloaded.chainId,
    contractAddress: UITestFixtures.CryptoCatalogPreloaded.contractAddress,
    result: TokenResolutionResult(
      coingeckoId: UITestFixtures.CryptoCatalogPreloaded.coingeckoMappingId,
      cryptocompareSymbol: UITestFixtures.CryptoCatalogPreloaded.cryptocompareSymbol,
      binanceSymbol: UITestFixtures.CryptoCatalogPreloaded.binanceSymbol,
      resolvedName: UITestFixtures.CryptoCatalogPreloaded.name,
      resolvedSymbol: UITestFixtures.CryptoCatalogPreloaded.symbol,
      resolvedDecimals: 18
    )
  )
}
