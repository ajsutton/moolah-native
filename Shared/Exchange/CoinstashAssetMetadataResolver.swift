import Foundation

/// Binds a `CoinstashClient` to a per-account bearer token so the
/// provider-neutral `ExchangeAssetMetadataResolving` seam carries no
/// token. Constructed per sync by `CoinstashSyncSource` once the
/// account's token is read from the keychain.
struct CoinstashAssetMetadataResolver: ExchangeAssetMetadataResolving, Sendable {
  private let client: CoinstashClient
  private let token: String

  init(client: CoinstashClient, token: String) {
    self.client = client
    self.token = token
  }

  func assetMetadata(forSymbol symbol: String) async throws -> ExchangeAssetMetadata? {
    try await client.coinMetadata(symbol: symbol, token: token)
  }
}
