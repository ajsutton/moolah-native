import XCTest

@testable import Moolah

final class CoinGeckoCatalogTypesTests: XCTestCase {
  func testPlatformBindingNormalisesContractAddressToLowercase() {
    let binding = PlatformBinding(slug: "ethereum", chainId: 1, contractAddress: "0xABCDef1234")
    XCTAssertEqual(binding.contractAddress, "0xabcdef1234")
  }

  func testCatalogEntryReturnsHighestPriorityPlatform() {
    let entry = CatalogEntry(
      coingeckoId: "usd-coin",
      symbol: "USDC",
      name: "USD Coin",
      platforms: [
        PlatformBinding(slug: "ethereum", chainId: 1, contractAddress: "0xethereum"),
        PlatformBinding(slug: "polygon-pos", chainId: 137, contractAddress: "0xpolygon"),
      ]
    )
    XCTAssertEqual(entry.preferredPlatform?.slug, "ethereum")
  }

  func testCatalogEntryWithoutPlatformsReturnsNilPreferred() {
    let entry = CatalogEntry(coingeckoId: "btc", symbol: "BTC", name: "Bitcoin", platforms: [])
    XCTAssertNil(entry.preferredPlatform)
  }
}
