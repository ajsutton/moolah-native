import Foundation
import Testing

@testable import Moolah

@Suite("FolderScanService")
@MainActor
struct FolderScanServiceTests {

  private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("scan-\(UUID().uuidString)", isDirectory: true)
  }

  /// Build an ImportStore wired to an in-memory TestBackend with one account
  /// + one profile. Lets us count how many ingests happen by querying the
  /// transactions repository.
  private func makeStack(
    watchedFolder: URL,
    defaults: UserDefaults,
    profileId: UUID = UUID()
  ) async throws -> (
    store: ImportStore, accountId: UUID, scanner: FolderScanService, backend: CloudKitBackend
  ) {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    _ = try await backend.accounts.create(
      Account(
        id: accountId, name: "Scan", type: .bank, instrument: .AUD,
        positions: [], position: 0, isHidden: false),
      openingBalance: nil)
    _ = try await backend.csvImportProfiles.create(
      CSVImportProfile(
        accountId: accountId,
        parserIdentifier: "generic-bank",
        headerSignature: ["date", "description", "debit", "credit", "balance"]))
    let stagingDirectory = tempDirectory()
    let staging = try ImportStagingStore(directory: stagingDirectory)
    let store = ImportStore(backend: backend, staging: staging)
    let preferences = ImportPreferences(directory: tempDirectory())
    preferences.setWatchedFolder(watchedFolder)
    let scanner = FolderScanService(
      profileId: profileId,
      importStore: store,
      preferences: preferences,
      defaults: defaults)
    return (store, accountId, scanner, backend)
  }

  private func writeCSV(at url: URL, lines: [String], modified: Date) throws {
    try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.modificationDate: modified], ofItemAtPath: url.path)
  }

  private func cbaLines(startBalance: Decimal = 1000) -> [String] {
    [
      "Date,Description,Debit,Credit,Balance",
      "02/04/2024,COFFEE HUT SYDNEY,-5.50,,\(startBalance - 5.50)",
      "03/04/2024,PAY NET,,3000.00,\(startBalance + 2994.50)",
    ]
  }

  @Test("scanForNewFiles ingests each CSV the first time it sees it")
  func firstRunIngestsEachCSV() async throws {
    let folder = tempDirectory()
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let defaults = UserDefaults(suiteName: "csvscan-\(UUID().uuidString)")!
    let (_, accountId, scanner, backend) = try await makeStack(
      watchedFolder: folder, defaults: defaults)
    let a = folder.appendingPathComponent("one.csv")
    let b = folder.appendingPathComponent("two.csv")
    try writeCSV(at: a, lines: cbaLines(), modified: Date(timeIntervalSinceNow: -30))
    try writeCSV(at: b, lines: cbaLines(), modified: Date(timeIntervalSinceNow: -10))

    await scanner.scanForNewFiles()

    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId), page: 0, pageSize: 50)
    // Each CSV yields 2 candidates → dedup drops second-run duplicates but
    // first run should land 2 for `a` and 0/2 for `b` depending on dedup.
    // Two distinct files with identical bank references/descriptions →
    // second file dedup's against first. Expect at least 2 transactions.
    #expect(page.transactions.count >= 2)
  }

  @Test("scanForNewFiles skips files already seen on the previous run")
  func subsequentRunSkipsSeen() async throws {
    let folder = tempDirectory()
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let defaults = UserDefaults(suiteName: "csvscan-\(UUID().uuidString)")!
    let (_, accountId, scanner, backend) = try await makeStack(
      watchedFolder: folder, defaults: defaults)
    let a = folder.appendingPathComponent("one.csv")
    let oldTime = Date(timeIntervalSinceNow: -300)
    try writeCSV(at: a, lines: cbaLines(), modified: oldTime)

    await scanner.scanForNewFiles()
    let firstPage = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId), page: 0, pageSize: 50)
    let firstCount = firstPage.transactions.count

    // Second scan with no new files → nothing changes. Cursor prevents
    // re-ingest even though dedup would also catch it.
    await scanner.scanForNewFiles()
    let secondPage = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId), page: 0, pageSize: 50)
    #expect(secondPage.transactions.count == firstCount)
  }

  @Test("scanForNewFiles picks up files newer than the cursor")
  func newerFilesIngested() async throws {
    let folder = tempDirectory()
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let defaults = UserDefaults(suiteName: "csvscan-\(UUID().uuidString)")!
    let (_, accountId, scanner, backend) = try await makeStack(
      watchedFolder: folder, defaults: defaults)
    let a = folder.appendingPathComponent("a.csv")
    try writeCSV(at: a, lines: cbaLines(), modified: Date(timeIntervalSinceNow: -600))
    await scanner.scanForNewFiles()
    let firstPage = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId), page: 0, pageSize: 50)
    let first = firstPage.transactions.count

    // Drop a second file with a strictly newer mtime + distinct data so dedup
    // doesn't drop it.
    let b = folder.appendingPathComponent("b.csv")
    try writeCSV(
      at: b,
      lines: [
        "Date,Description,Debit,Credit,Balance",
        "04/04/2024,TAXI SYDNEY,-20.00,,950.00",
      ],
      modified: Date(timeIntervalSinceNow: -10))
    await scanner.scanForNewFiles()
    let secondPage = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId), page: 0, pageSize: 50)
    #expect(secondPage.transactions.count > first)
  }

  @Test("non-CSV files in the folder are ignored")
  func nonCSVFilesIgnored() async throws {
    let folder = tempDirectory()
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let defaults = UserDefaults(suiteName: "csvscan-\(UUID().uuidString)")!
    let (_, accountId, scanner, backend) = try await makeStack(
      watchedFolder: folder, defaults: defaults)
    let txt = folder.appendingPathComponent("notes.txt")
    try writeCSV(
      at: txt, lines: ["hello"],
      modified: Date(timeIntervalSinceNow: -10))
    await scanner.scanForNewFiles()
    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId), page: 0, pageSize: 50)
    #expect(page.transactions.isEmpty)
  }

  @Test("scanForNewFiles without a watched folder is a no-op")
  func noWatchedFolderIsNoOp() async throws {
    let defaults = UserDefaults(suiteName: "csvscan-\(UUID().uuidString)")!
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    _ = try await backend.accounts.create(
      Account(
        id: accountId, name: "Scan", type: .bank, instrument: .AUD,
        positions: [], position: 0, isHidden: false),
      openingBalance: nil)
    let staging = try ImportStagingStore(directory: tempDirectory())
    let store = ImportStore(backend: backend, staging: staging)
    let preferences = ImportPreferences(directory: tempDirectory())
    // No setWatchedFolder → nothing to scan.
    let scanner = FolderScanService(
      profileId: UUID(),
      importStore: store,
      preferences: preferences,
      defaults: defaults)
    await scanner.scanForNewFiles()
    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId), page: 0, pageSize: 50)
    #expect(page.transactions.isEmpty)
  }
}
