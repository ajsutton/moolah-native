import Foundation
import Testing

@testable import Moolah

// Serialised because both tests mutate `URL.moolahApplicationSupportOverride`,
// a `nonisolated(unsafe)` static. Parallel execution would let one test's
// override leak into the other's assertions.
@Suite("URL+MoolahStorage", .serialized)
struct URLMoolahStorageTests {
  @Test("returns <root>/<env>/ with env subdir created")
  func testScopedRootUsesEnvironmentSubdirectory() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    URL.moolahApplicationSupportOverride = root
    defer { URL.moolahApplicationSupportOverride = nil }

    let scoped = URL.moolahScopedApplicationSupport

    let expected = root.appending(path: CloudKitEnvironment.resolved().storageSubdirectory)
    #expect(scoped.standardizedFileURL == expected.standardizedFileURL)
    #expect(FileManager.default.fileExists(atPath: scoped.path()))
  }

  @Test("falls back to Application Support when no override is set")
  func testScopedRootDefaultsToApplicationSupport() {
    URL.moolahApplicationSupportOverride = nil
    let scoped = URL.moolahScopedApplicationSupport
    let expectedPrefix = URL.applicationSupportDirectory
      .appending(path: CloudKitEnvironment.resolved().storageSubdirectory)
    #expect(scoped.standardizedFileURL == expectedPrefix.standardizedFileURL)
  }
}
