// MoolahTests/Domain/Models/WalletSyncErrorTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("WalletSyncError")
struct WalletSyncErrorTests {
  @Test("Static factories produce provider-less errors")
  func factoriesAreUnattributed() {
    #expect(WalletSyncError.missingApiKey.provider == nil)
    #expect(WalletSyncError.missingApiKey.kind == .missingApiKey)
    let net = WalletSyncError.network(underlyingDescription: "boom")
    #expect(net.provider == nil)
    #expect(net.kind == .network(underlyingDescription: "boom"))
  }

  @Test("attributed(to:) stamps an unattributed error")
  func attributedStampsWhenNil() {
    let stamped = WalletSyncError.network(underlyingDescription: "x")
      .attributed(to: .alchemy)
    #expect(stamped.provider == .alchemy)
    #expect(stamped.kind == .network(underlyingDescription: "x"))
  }

  @Test("attributed(to:) is innermost-wins — does not overwrite")
  func attributedDoesNotOverwrite() {
    let inner = WalletSyncError(provider: .blockExplorer, kind: .invalidApiKey)
    let outer = inner.attributed(to: .alchemy)
    #expect(outer.provider == .blockExplorer)
  }

  @Test("New shape round-trips through JSON")
  func newShapeRoundTrips() throws {
    let original = WalletSyncError(
      provider: .coinstash, kind: .rateLimited(retryAfter: nil))
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(WalletSyncError.self, from: data)
    #expect(decoded == original)
  }

  @Test("Legacy bare-enum JSON decodes as provider: nil")
  func legacyJSONDecodes() throws {
    let legacy = #"{"network":{"underlyingDescription":"old failure"}}"#
    let decoded = try JSONDecoder().decode(
      WalletSyncError.self, from: Data(legacy.utf8))
    #expect(decoded.provider == nil)
    #expect(decoded.kind == .network(underlyingDescription: "old failure"))
  }

  @Test("Legacy bare-enum JSON for a no-payload case decodes")
  func legacyNoPayloadCaseDecodes() throws {
    let legacy = #"{"missingApiKey":{}}"#
    let decoded = try JSONDecoder().decode(
      WalletSyncError.self, from: Data(legacy.utf8))
    #expect(decoded.provider == nil)
    #expect(decoded.kind == .missingApiKey)
  }

  @Test("rateLimited with a non-nil retryAfter survives JSON round-trip")
  func rateLimitedDateRoundTrips() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let original = WalletSyncError(
      provider: .alchemy, kind: .rateLimited(retryAfter: date))
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(WalletSyncError.self, from: data)
    #expect(decoded == original)
    #expect(decoded.kind == .rateLimited(retryAfter: date))
  }
}
