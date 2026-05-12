#if os(macOS)
  import Foundation
  import GRDB
  import Testing

  @testable import Moolah

  @MainActor
  @Suite("StoreBackupManager")
  struct StoreBackupManagerTests {
    let tempDir: URL
    let manager: StoreBackupManager

    init() throws {
      tempDir = FileManager.default.temporaryDirectory
        .appending(path: "StoreBackupManagerTests-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
      manager = StoreBackupManager(backupDirectory: tempDir, retentionDays: 7)
    }

    // MARK: - hasBackupForToday

    @Test("hasBackupForToday returns false when no backup exists")
    func hasBackupForTodayReturnsFalseWhenNoBackup() {
      let profileId = UUID()
      #expect(!manager.hasBackupForToday(profileId: profileId))
    }

    @Test("hasBackupForToday returns true when today's backup exists")
    func hasBackupForTodayReturnsTrueWhenBackupExists() throws {
      let profileId = UUID()
      let profileDir = tempDir.appending(path: profileId.uuidString)
      try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

      let formatter = DateFormatter()
      formatter.dateFormat = "yyyy-MM-dd"
      let today = formatter.string(from: Date())
      let backupURL = profileDir.appending(path: "\(today).sqlite")
      FileManager.default.createFile(atPath: backupURL.path(), contents: Data("test".utf8))

      #expect(manager.hasBackupForToday(profileId: profileId))
    }

    // MARK: - pruneBackups

    @Test("pruneBackups keeps only retentionDays backups")
    func pruneBackupsKeepsOnlyRetentionDays() throws {
      let profileId = UUID()
      let profileDir = tempDir.appending(path: profileId.uuidString)
      try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

      // Create 10 date-stamped .sqlite files
      for day in 1...10 {
        let filename = "2026-04-\(String(format: "%02d", day)).sqlite"
        let fileURL = profileDir.appending(path: filename)
        FileManager.default.createFile(atPath: fileURL.path(), contents: Data("test".utf8))
      }

      manager.pruneBackups(profileId: profileId)

      let remaining = try FileManager.default.contentsOfDirectory(atPath: profileDir.path())
        .filter { $0.hasSuffix(".sqlite") }
      #expect(remaining.count == 7)

      // Should keep the 7 most recent (sorted reverse, dropFirst(7) removes oldest 3)
      let expectedRemoved = ["2026-04-01.sqlite", "2026-04-02.sqlite", "2026-04-03.sqlite"]
      for filename in expectedRemoved {
        #expect(
          !FileManager.default.fileExists(atPath: profileDir.appending(path: filename).path()))
      }
    }

    @Test("pruneBackups does nothing when fewer than retentionDays backups exist")
    func pruneBackupsDoesNothingWhenFewer() throws {
      let profileId = UUID()
      let profileDir = tempDir.appending(path: profileId.uuidString)
      try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

      for day in 1...3 {
        let filename = "2026-04-\(String(format: "%02d", day)).sqlite"
        let fileURL = profileDir.appending(path: filename)
        FileManager.default.createFile(atPath: fileURL.path(), contents: Data("test".utf8))
      }

      manager.pruneBackups(profileId: profileId)

      let remaining = try FileManager.default.contentsOfDirectory(atPath: profileDir.path())
        .filter { $0.hasSuffix(".sqlite") }
      #expect(remaining.count == 3)
    }

    // MARK: - backupStore

    @Test("backupStore skips if today's backup already exists")
    func backupStoreSkipsIfAlreadyBackedUp() async throws {
      let profileId = UUID()
      let profileDir = tempDir.appending(path: profileId.uuidString)
      try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

      let formatter = DateFormatter()
      formatter.dateFormat = "yyyy-MM-dd"
      let today = formatter.string(from: Date())
      let backupURL = profileDir.appending(path: "\(today).sqlite")
      let originalData = Data("original".utf8)
      FileManager.default.createFile(atPath: backupURL.path(), contents: originalData)

      // Use an in-memory GRDB queue as the source — backupStore should
      // short-circuit before issuing VACUUM INTO when today's backup
      // exists, so the sentinel `originalData` must survive untouched.
      let database = try ProfileDatabase.openInMemory()
      try await manager.backupStore(from: database, profileId: profileId)

      // Original file should be unchanged (backup was skipped)
      let data = try Data(contentsOf: backupURL)
      #expect(data == originalData)
    }

    @Test("backupStore creates profile directory and writes today's backup")
    func backupStoreCreatesProfileDirectory() async throws {
      let profileId = UUID()
      let profileDir = tempDir.appending(path: profileId.uuidString)

      // Profile directory should not exist yet
      #expect(!FileManager.default.fileExists(atPath: profileDir.path()))

      // Use an on-disk source DB so VACUUM INTO has a real source to
      // copy from. `:memory:` would also work, but on-disk mirrors
      // production more closely.
      let sourceDir = tempDir.appending(path: "source-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
      let sourceURL = sourceDir.appending(path: "data.sqlite")
      let database = try ProfileDatabase.open(at: sourceURL)

      try await manager.backupStore(from: database, profileId: profileId)

      // Profile directory should now exist
      #expect(FileManager.default.fileExists(atPath: profileDir.path()))

      // Today's backup should exist
      #expect(manager.hasBackupForToday(profileId: profileId))
    }
  }
#endif
