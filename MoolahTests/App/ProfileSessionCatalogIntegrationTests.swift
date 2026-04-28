// MoolahTests/App/ProfileSessionCatalogIntegrationTests.swift
import Foundation
import Testing

@testable import Moolah

// Serialised because the suite mutates `URL.moolahApplicationSupportOverride`,
// a `nonisolated(unsafe)` static, to keep the on-disk SQLite catalogue out
// of the user's real Application Support directory. Parallel execution would
// let one test's override leak into another's assertions.
@Suite("ProfileSession — CoinGecko catalog wiring", .serialized)
@MainActor
struct ProfileSessionCatalogIntegrationTests {
  @Test("CloudKit profile exposes a non-nil CoinGecko catalog")
  func cloudKitProfileExposesCatalog() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "ProfileSessionCatalogIntegrationTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    URL.moolahApplicationSupportOverride = root
    // The catalog actor outlives this test (a background `refreshIfStale()`
    // task captures it); deleting `root` here would race with the actor's
    // SQLite handle and produce noisy "vnode unlinked while in use" logs
    // from libsqlite3. The temp directory is reaped by the OS on exit.
    defer { URL.moolahApplicationSupportOverride = nil }

    let containerManager = try ProfileContainerManager.forTesting()
    let profile = Profile(
      label: "iCloud",
      currencyCode: "AUD", financialYearStartMonth: 7
    )
    let session = ProfileSession(profile: profile, containerManager: containerManager)

    #expect(session.coinGeckoCatalog != nil)
  }
}
