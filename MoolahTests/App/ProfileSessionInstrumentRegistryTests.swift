// MoolahTests/App/ProfileSessionInstrumentRegistryTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("ProfileSession — instrumentRegistry wiring")
@MainActor
struct ProfileSessionInstrumentRegistryTests {
  @Test("CloudKit profile has both registry and cryptoTokenStore")
  func cloudKitProfileHasRegistry() throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let profile = Profile(
      label: "iCloud", backendType: .cloudKit,
      currencyCode: "AUD", financialYearStartMonth: 7
    )
    let session = ProfileSession(profile: profile, containerManager: containerManager)

    #expect(session.instrumentRegistry != nil)
    #expect(session.cryptoTokenStore != nil)
  }

  @Test("Remote profile has no registry and no cryptoTokenStore")
  func remoteProfileHasNoRegistry() throws {
    let url = try #require(URL(string: "https://moolah.rocks/api/"))
    let profile = Profile(label: "Remote", serverURL: url)
    let session = ProfileSession(profile: profile)

    #expect(session.instrumentRegistry == nil)
    #expect(session.cryptoTokenStore == nil)
  }
}
