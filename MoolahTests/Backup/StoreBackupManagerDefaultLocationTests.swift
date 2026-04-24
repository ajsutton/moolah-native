#if os(macOS)
  import Foundation
  import Testing

  @testable import Moolah

  // Serialised because it mutates `URL.moolahApplicationSupportOverride`,
  // a `nonisolated(unsafe)` static. See URLMoolahStorageTests for the
  // same pattern.
  @Suite("StoreBackupManager default location", .serialized)
  struct StoreBackupManagerDefaultLocationTests {
    @Test("default backup directory is scoped by CloudKit environment")
    @MainActor
    func testDefaultBackupDirectoryIsScoped() throws {
      let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }

      URL.moolahApplicationSupportOverride = root
      defer { URL.moolahApplicationSupportOverride = nil }

      let manager = StoreBackupManager()

      let envSubdir = CloudKitEnvironment.resolved().storageSubdirectory
      let expected =
        root
        .appending(path: envSubdir)
        .appending(path: "Moolah/Backups")
      #expect(manager.testingBackupDirectory.standardizedFileURL == expected.standardizedFileURL)
    }
  }
#endif
