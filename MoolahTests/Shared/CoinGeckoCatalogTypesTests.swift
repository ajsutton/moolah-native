import Testing

@testable import Moolah

@Suite("CoinGeckoCatalog types")
struct CoinGeckoCatalogTypesTests {
  @Test
  func platformBindingNormalisesContractAddressToLowercase() {
    let binding = PlatformBinding(slug: "ethereum", chainId: 1, contractAddress: "0xABCDef1234")
    #expect(binding.contractAddress == "0xabcdef1234")
  }

  @Test
  func catalogEntryReturnsHighestPriorityPlatform() {
    let entry = CatalogEntry(
      coingeckoId: "usd-coin",
      symbol: "USDC",
      name: "USD Coin",
      platforms: [
        PlatformBinding(slug: "ethereum", chainId: 1, contractAddress: "0xethereum"),
        PlatformBinding(slug: "polygon-pos", chainId: 137, contractAddress: "0xpolygon"),
      ]
    )
    #expect(entry.preferredPlatform?.slug == "ethereum")
  }

  @Test
  func catalogEntryWithoutPlatformsReturnsNilPreferred() {
    let entry = CatalogEntry(coingeckoId: "btc", symbol: "BTC", name: "Bitcoin", platforms: [])
    #expect(entry.preferredPlatform == nil)
  }
}
