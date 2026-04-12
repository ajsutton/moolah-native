import Foundation

struct ICloudTokenRepository: CryptoTokenRepository, Sendable {
  private static let key = "crypto-tokens"

  func loadTokens() async throws -> [CryptoToken] {
    guard let data = NSUbiquitousKeyValueStore.default.data(forKey: Self.key) else {
      return []
    }
    return try JSONDecoder().decode([CryptoToken].self, from: data)
  }

  func saveTokens(_ tokens: [CryptoToken]) async throws {
    let data = try JSONEncoder().encode(tokens)
    NSUbiquitousKeyValueStore.default.set(data, forKey: Self.key)
    NSUbiquitousKeyValueStore.default.synchronize()
  }
}
