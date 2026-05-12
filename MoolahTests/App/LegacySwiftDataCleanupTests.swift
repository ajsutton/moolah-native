import Foundation
import Testing

@testable import Moolah

// Serialised because each test mutates `URL.moolahApplicationSupportOverride`,
// a `nonisolated(unsafe)` static. Parallel execution would let one test's
// override leak into another. See URLMoolahStorageTests for the same pattern.
@Suite("MoolahApp.cleanupLegacySwiftDataStoresOnce", .serialized)
@MainActor
struct LegacySwiftDataCleanupTests {
  /// Allocates a fresh temporary directory rooted under
  /// `FileManager.default.temporaryDirectory` and installs it as the
  /// `URL.moolahApplicationSupportOverride`. Returns the *scoped*
  /// directory (i.e. the env subdir created by
  /// `URL.moolahScopedApplicationSupport`) so callers can seed files
  /// directly into the directory the helper will scan.
  ///
  /// The caller is responsible for clearing the override and removing
  /// the temp root in a `defer` block.
  private static func makeScopedTempDirectory() throws -> (root: URL, scoped: URL) {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    URL.moolahApplicationSupportOverride = root
    // Reading `moolahScopedApplicationSupport` creates the env subdirectory
    // on demand, so the test can seed files into it without an extra
    // `createDirectory` step.
    let scoped = URL.moolahScopedApplicationSupport
    return (root: root, scoped: scoped)
  }

  /// Creates a fresh isolated `UserDefaults` suite so the cleanup flag
  /// doesn't bleed across tests or pollute the user's standard domain.
  private static func makeIsolatedDefaults() throws -> UserDefaults {
    let suiteName = "test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  /// Writes an empty file at `url`, creating any missing parents. Used to
  /// stand in for SwiftData store files and their `-shm` / `-wal` sidecars.
  private static func seedEmptyFile(at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: url)
  }

  @Test("removes profile-index and per-profile SwiftData stores; leaves controls intact")
  func removesProfileIndexAndPerProfileStores() throws {
    let (root, scoped) = try Self.makeScopedTempDirectory()
    defer {
      URL.moolahApplicationSupportOverride = nil
      try? FileManager.default.removeItem(at: root)
    }
    let defaults = try Self.makeIsolatedDefaults()

    let profileIndexFiles = [
      scoped.appending(path: "Moolah-v2.store"),
      scoped.appending(path: "Moolah-v2.store-shm"),
      scoped.appending(path: "Moolah-v2.store-wal"),
    ]
    let profileUUID = UUID().uuidString
    let perProfileFiles = [
      scoped.appending(path: "Moolah-\(profileUUID).store"),
      scoped.appending(path: "Moolah-\(profileUUID).store-shm"),
      scoped.appending(path: "Moolah-\(profileUUID).store-wal"),
    ]
    let control = scoped.appending(path: "Moolah-other.txt")
    for url in profileIndexFiles + perProfileFiles + [control] {
      try Self.seedEmptyFile(at: url)
    }

    MoolahApp.cleanupLegacySwiftDataStoresOnce(defaults: defaults)

    for url in profileIndexFiles + perProfileFiles {
      #expect(
        !FileManager.default.fileExists(atPath: url.path()),
        "expected legacy store file to be removed: \(url.lastPathComponent)")
    }
    #expect(
      FileManager.default.fileExists(atPath: control.path()),
      "control file must not be deleted")
    #expect(defaults.bool(forKey: "v4.swiftDataStores.cleared") == true)
  }

  @Test("is idempotent once the flag is set: a re-seeded store is left untouched")
  func isIdempotentOnceFlagSet() throws {
    let (root, scoped) = try Self.makeScopedTempDirectory()
    defer {
      URL.moolahApplicationSupportOverride = nil
      try? FileManager.default.removeItem(at: root)
    }
    let defaults = try Self.makeIsolatedDefaults()
    // Pre-set the flag as if a previous run had completed.
    defaults.set(true, forKey: "v4.swiftDataStores.cleared")

    let reseeded = scoped.appending(path: "Moolah-v2.store")
    try Self.seedEmptyFile(at: reseeded)

    MoolahApp.cleanupLegacySwiftDataStoresOnce(defaults: defaults)

    #expect(
      FileManager.default.fileExists(atPath: reseeded.path()),
      "re-entry must short-circuit on the flag and not delete the new store")
  }

  @Test("re-entry is safe when the directory is empty")
  func reentryIsSafeWhenDirectoryEmpty() throws {
    let (root, _) = try Self.makeScopedTempDirectory()
    defer {
      URL.moolahApplicationSupportOverride = nil
      try? FileManager.default.removeItem(at: root)
    }
    let defaults = try Self.makeIsolatedDefaults()

    MoolahApp.cleanupLegacySwiftDataStoresOnce(defaults: defaults)

    #expect(defaults.bool(forKey: "v4.swiftDataStores.cleared") == true)
  }
}
