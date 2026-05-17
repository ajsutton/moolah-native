import Testing

@testable import Moolah

@Suite("ExchangeAssetMetadata value type")
struct CoinstashCoinMetadataTests {
  @Test
  func chainStoresContractAndDecimals() {
    let chain = ExchangeAssetChain(
      chainId: 1, contractAddress: "0xA0B8…", decimals: 6)
    let meta = ExchangeAssetMetadata(symbol: "USDC", name: "USDC", chains: [chain])
    #expect(meta.symbol == "USDC")
    #expect(meta.chains.first?.chainId == 1)
    #expect(meta.chains.first?.decimals == 6)
  }
}
