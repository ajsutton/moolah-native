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
      currencyCode: "USD",
      financialYearStartMonth: 1,
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
    #expect(decoded.currencyCode == "USD")
    #expect(decoded.financialYearStartMonth == 1)
    #expect(decoded.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
  }

  @Test("defaults: AUD currency and July FY start")
  func defaults() {
    let profile = Profile(
      label: "Moolah",
      serverURL: URL(string: "https://moolah.rocks/api/")!
    )

    #expect(!profile.id.uuidString.isEmpty)
    #expect(profile.backendType == .remote)
    #expect(profile.cachedUserName == nil)
    #expect(profile.currencyCode == "AUD")
    #expect(profile.financialYearStartMonth == 7)
    #expect(profile.currency == .AUD)
    #expect(profile.createdAt.timeIntervalSince1970 > 0)
  }

  @Test("currency computed property maps known codes")
  func currencyMapping() {
    var profile = Profile(label: "Test", serverURL: URL(string: "https://test.com/")!)

    profile.currencyCode = "AUD"
    #expect(profile.currency == .AUD)

    profile.currencyCode = "USD"
    #expect(profile.currency == .USD)

    profile.currencyCode = "GBP"
    #expect(profile.currency.code == "GBP")
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
