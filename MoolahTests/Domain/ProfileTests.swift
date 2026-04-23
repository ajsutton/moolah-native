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
    #expect(profile.currencyCode == "AUD")
    #expect(profile.financialYearStartMonth == 7)
    #expect(profile.instrument == .AUD)
    #expect(profile.createdAt.timeIntervalSince1970 > 0)
  }

  @Test("instrument computed property maps known codes")
  func instrumentMapping() {
    var profile = Profile(label: "Test", serverURL: URL(string: "https://test.com/")!)

    profile.currencyCode = "AUD"
    #expect(profile.instrument == .AUD)

    profile.currencyCode = "USD"
    #expect(profile.instrument == .USD)

    profile.currencyCode = "GBP"
    #expect(profile.instrument.id == "GBP")
  }

  @Test("equality compares all fields")
  func equality() {
    let id = UUID()
    let date = Date()
    let first = Profile(
      id: id, label: "A", serverURL: URL(string: "https://first.com/")!, createdAt: date)
    let second = Profile(
      id: id, label: "A", serverURL: URL(string: "https://first.com/")!, createdAt: date)
    let third = Profile(
      id: id, label: "B", serverURL: URL(string: "https://first.com/")!, createdAt: date)

    #expect(first == second)
    #expect(first != third)
  }

  @Test("moolah profile resolves to moolah.rocks URL")
  func moolahResolvedURL() {
    let profile = Profile(label: "Moolah", backendType: .moolah)

    #expect(profile.serverURL == nil)
    #expect(profile.resolvedServerURL == Profile.moolahServerURL)
    #expect(profile.resolvedServerURL.absoluteString == "https://moolah.rocks/api/")
  }

  @Test("remote profile resolves to stored URL")
  func remoteResolvedURL() {
    let url = URL(string: "https://custom.example.com/api/")!
    let profile = Profile(label: "Custom", backendType: .remote, serverURL: url)

    #expect(profile.serverURL == url)
    #expect(profile.resolvedServerURL == url)
  }

  @Test("BackendType round-trips through JSON")
  func backendTypeRoundTrip() throws {
    let data = try JSONEncoder().encode(BackendType.remote)
    let decoded = try JSONDecoder().decode(BackendType.self, from: data)
    #expect(decoded == .remote)
  }

  @Test("moolah BackendType round-trips through JSON")
  func moolahBackendTypeRoundTrip() throws {
    let data = try JSONEncoder().encode(BackendType.moolah)
    let decoded = try JSONDecoder().decode(BackendType.self, from: data)
    #expect(decoded == .moolah)
  }

  @Test("supportsComplexTransactions is false for remote backend")
  func supportsComplexTransactionsRemote() {
    let profile = Profile(label: "Remote", backendType: .remote)
    #expect(!profile.supportsComplexTransactions)
  }

  @Test("supportsComplexTransactions is false for moolah backend")
  func supportsComplexTransactionsMoolah() {
    let profile = Profile(label: "Moolah", backendType: .moolah)
    #expect(!profile.supportsComplexTransactions)
  }

  @Test("supportsComplexTransactions is true for cloudKit backend")
  func supportsComplexTransactionsCloudKit() {
    let profile = Profile(label: "iCloud", backendType: .cloudKit)
    #expect(profile.supportsComplexTransactions)
  }
}
