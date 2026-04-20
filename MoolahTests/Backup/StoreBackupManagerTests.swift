#if os(macOS)
  import Foundation
  import SwiftData
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
      let backupURL = profileDir.appending(path: "\(today).store")
      FileManager.default.createFile(atPath: backupURL.path(), contents: Data("test".utf8))

      #expect(manager.hasBackupForToday(profileId: profileId))
    }

    // MARK: - pruneBackups

    @Test("pruneBackups keeps only retentionDays backups")
    func pruneBackupsKeepsOnlyRetentionDays() throws {
      let profileId = UUID()
      let profileDir = tempDir.appending(path: profileId.uuidString)
      try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

      // Create 10 date-stamped .store files
      for day in 1...10 {
        let filename = "2026-04-\(String(format: "%02d", day)).store"
        let fileURL = profileDir.appending(path: filename)
        FileManager.default.createFile(atPath: fileURL.path(), contents: Data("test".utf8))
      }

      manager.pruneBackups(profileId: profileId)

      let remaining = try FileManager.default.contentsOfDirectory(atPath: profileDir.path())
        .filter { $0.hasSuffix(".store") }
      #expect(remaining.count == 7)

      // Should keep the 7 most recent (sorted reverse, dropFirst(7) removes oldest 3)
      let expectedRemoved = ["2026-04-01.store", "2026-04-02.store", "2026-04-03.store"]
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
        let filename = "2026-04-\(String(format: "%02d", day)).store"
        let fileURL = profileDir.appending(path: filename)
        FileManager.default.createFile(atPath: fileURL.path(), contents: Data("test".utf8))
      }

      manager.pruneBackups(profileId: profileId)

      let remaining = try FileManager.default.contentsOfDirectory(atPath: profileDir.path())
        .filter { $0.hasSuffix(".store") }
      #expect(remaining.count == 3)
    }

    // MARK: - backupStore

    @Test("backupStore skips if today's backup already exists")
    func backupStoreSkipsIfAlreadyBackedUp() throws {
      let profileId = UUID()
      let profileDir = tempDir.appending(path: profileId.uuidString)
      try FileManager.default.createDirectory(at: profileDir, withIntermediateDirectories: true)

      let formatter = DateFormatter()
      formatter.dateFormat = "yyyy-MM-dd"
      let today = formatter.string(from: Date())
      let backupURL = profileDir.appending(path: "\(today).store")
      let originalData = Data("original".utf8)
      FileManager.default.createFile(atPath: backupURL.path(), contents: originalData)

      // Create a dummy source file — backupStore should skip before even trying to copy
      let sourceURL = tempDir.appending(path: "source.store")
      FileManager.default.createFile(atPath: sourceURL.path(), contents: Data("new".utf8))

      try manager.backupStore(at: sourceURL, profileId: profileId)

      // Original file should be unchanged (backup was skipped)
      let data = try Data(contentsOf: backupURL)
      #expect(data == originalData)
    }

    @Test("backupStore creates profile directory on first backup")
    func backupStoreCreatesProfileDirectory() throws {
      let profileId = UUID()
      let profileDir = tempDir.appending(path: profileId.uuidString)

      // Profile directory should not exist yet
      #expect(!FileManager.default.fileExists(atPath: profileDir.path()))

      // Create a real SQLite file to back up using SwiftData
      let sourceDir = tempDir.appending(path: "source-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
      let sourceURL = sourceDir.appending(path: "test.store")

      // Create a minimal SQLite database via SwiftData
      let schema = Schema([
        AccountRecord.self, TransactionRecord.self, TransactionLegRecord.self,
        InstrumentRecord.self, CategoryRecord.self,
        EarmarkRecord.self, EarmarkBudgetItemRecord.self,
        InvestmentValueRecord.self,
        CSVImportProfileRecord.self,
        ImportRuleRecord.self,
      ])
      let config = ModelConfiguration(url: sourceURL)
      _ = try ModelContainer(for: schema, configurations: [config])

      try manager.backupStore(at: sourceURL, profileId: profileId)

      // Profile directory should now exist
      #expect(FileManager.default.fileExists(atPath: profileDir.path()))

      // Today's backup should exist
      #expect(manager.hasBackupForToday(profileId: profileId))
    }
  }
#endif
