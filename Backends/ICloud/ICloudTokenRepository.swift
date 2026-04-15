import Foundation

struct ICloudTokenRepository: CryptoTokenRepository, Sendable {
  private static let key = "crypto-tokens"

  func loadRegistrations() async throws -> [CryptoRegistration] {
    guard let data = NSUbiquitousKeyValueStore.default.data(forKey: Self.key) else {
      return []
    }
    return try JSONDecoder().decode([CryptoRegistration].self, from: data)
  }

  func saveRegistrations(_ registrations: [CryptoRegistration]) async throws {
    let data = try JSONEncoder().encode(registrations)
    NSUbiquitousKeyValueStore.default.set(data, forKey: Self.key)
    NSUbiquitousKeyValueStore.default.synchronize()
  }
}
