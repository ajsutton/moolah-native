import Foundation
import Testing

@testable import Moolah

@Suite("Profile")
struct ProfileTests {
  @Test("JSON round-trip preserves all fields")
  func jsonRoundTrip() throws {
    let profile = Profile(
      id: UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!,
      label: "Work Server",
      backendType: .remote,
      serverURL: URL(string: "https://moolah.rocks/api/")!,
      cachedUserName: "Ada Lovelace",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let data = try JSONEncoder().encode(profile)
    let decoded = try JSONDecoder().decode(Profile.self, from: data)

    #expect(decoded == profile)
    #expect(decoded.id == profile.id)
    #expect(decoded.label == "Work Server")
    #expect(decoded.backendType == .remote)
    #expect(decoded.serverURL == URL(string: "https://moolah.rocks/api/")!)
    #expect(decoded.cachedUserName == "Ada Lovelace")
    #expect(decoded.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
  }

  @Test("defaults: generates UUID, sets createdAt, nil cachedUserName")
  func defaults() {
    let profile = Profile(
      label: "Moolah",
      serverURL: URL(string: "https://moolah.rocks/api/")!
    )

    #expect(!profile.id.uuidString.isEmpty)
    #expect(profile.backendType == .remote)
    #expect(profile.cachedUserName == nil)
    #expect(profile.createdAt.timeIntervalSince1970 > 0)
  }

  @Test("equality compares all fields")
  func equality() {
    let id = UUID()
    let date = Date()
    let a = Profile(id: id, label: "A", serverURL: URL(string: "https://a.com/")!, createdAt: date)
    let b = Profile(id: id, label: "A", serverURL: URL(string: "https://a.com/")!, createdAt: date)
    let c = Profile(
      id: id, label: "B", serverURL: URL(string: "https://a.com/")!, createdAt: date)

    #expect(a == b)
    #expect(a != c)
  }

  @Test("BackendType round-trips through JSON")
  func backendTypeRoundTrip() throws {
    let data = try JSONEncoder().encode(BackendType.remote)
    let decoded = try JSONDecoder().decode(BackendType.self, from: data)
    #expect(decoded == .remote)
  }
}
