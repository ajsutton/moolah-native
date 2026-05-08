// MoolahTests/Backends/SQLiteCoinGeckoCatalogParseTests.swift
import Foundation
import Testing

@testable import Moolah

/// Parser dedupe behaviour. CoinGecko's `/coins/list` and `/asset_platforms`
/// endpoints occasionally include the same `id` / `slug` more than once
/// (typically around delistings or platform renames). The downstream tables
/// have UNIQUE/PRIMARY-KEY constraints, so a duplicate row would abort the
/// `replaceAll` transaction and freeze the catalog at its prior snapshot.
/// Dedupe in the parser keeps the on-disk constraints strict (so genuine
/// bugs in our insert path still trap) without letting a single bad upstream
/// row take out the whole refresh.
@Suite("SQLiteCoinGeckoCatalog parse")
struct SQLiteCoinGeckoCatalogParseTests {
  @Test
  func parseCoinsKeepsFirstOccurrenceWhenIdRepeats() throws {
    let json = Data(
      """
      [
        {"id": "tether", "symbol": "usdt", "name": "Tether", "platforms": {}},
        {"id": "bitcoin", "symbol": "btc", "name": "Bitcoin", "platforms": {}},
        {"id": "tether", "symbol": "usdt", "name": "Tether (dup)", "platforms": {}}
      ]
      """.utf8)

    let coins = try SQLiteCoinGeckoCatalog.parseCoins(json)

    #expect(coins.map(\.id) == ["tether", "bitcoin"])
    #expect(coins.first(where: { $0.id == "tether" })?.name == "Tether")
  }

  @Test
  func parsePlatformsKeepsFirstOccurrenceWhenSlugRepeats() throws {
    let json = Data(
      """
      [
        {"id": "ethereum", "chain_identifier": 1, "name": "Ethereum"},
        {"id": "polygon-pos", "chain_identifier": 137, "name": "Polygon POS"},
        {"id": "ethereum", "chain_identifier": 1, "name": "Ethereum (dup)"}
      ]
      """.utf8)

    let platforms = try SQLiteCoinGeckoCatalog.parsePlatforms(json)

    #expect(platforms.map(\.slug) == ["ethereum", "polygon-pos"])
    #expect(platforms.first(where: { $0.slug == "ethereum" })?.name == "Ethereum")
  }

  @Test
  func compactPlatformsDropsNullAndEmptyContracts() {
    let raw: [String: String?] = [
      "ethereum": "0xabc",
      "polygon-pos": nil,
      "binance-smart-chain": "",
      "arbitrum-one": "0xdef",
    ]

    let compacted = SQLiteCoinGeckoCatalog.compactPlatforms(raw)

    #expect(compacted == ["ethereum": "0xabc", "arbitrum-one": "0xdef"])
  }

  @Test
  func parseCoinsLeavesUniqueIdsUntouched() throws {
    let json = Data(
      """
      [
        {"id": "bitcoin", "symbol": "btc", "name": "Bitcoin", "platforms": {}},
        {"id": "ethereum", "symbol": "eth", "name": "Ethereum", "platforms": {}}
      ]
      """.utf8)

    let coins = try SQLiteCoinGeckoCatalog.parseCoins(json)

    #expect(coins.map(\.id) == ["bitcoin", "ethereum"])
  }
}
