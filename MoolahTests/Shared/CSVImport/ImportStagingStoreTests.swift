import Foundation
import Testing

@testable import Moolah

@Suite("ImportStagingStore")
struct ImportStagingStoreTests {

  private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
  }

  private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  @Test("empty directory returns empty pending and failed lists")
  func emptyDirectoryReturnsEmptyLists() async throws {
    let dir = tempDirectory()
    defer { cleanup(dir) }
    let store = try ImportStagingStore(directory: dir)
    let pending = try await store.pendingFiles()
    let failed = try await store.failedFiles()
    #expect(pending.isEmpty)
    #expect(failed.isEmpty)
  }

  @Test("stagePending persists the file and its entry survives re-opening the store")
  func stagePendingRoundTrip() async throws {
    let dir = tempDirectory()
    defer { cleanup(dir) }
    let firstStore = try ImportStagingStore(directory: dir)
    let id = UUID()
    let stagingPath = await firstStore.stagingPath(for: id)
    let file = PendingSetupFile(
      id: id,
      originalFilename: "cba.csv",
      stagingPath: stagingPath,
      securityScopedBookmark: nil,
      detectedParserIdentifier: "generic-bank",
      detectedHeaders: ["date", "amount", "description", "balance"],
      parsedAt: Date(timeIntervalSince1970: 1_700_000_000),
      sourceBookmark: nil)
    let bytes = Data("Date,Description,Amount,Balance\n02/04/2024,COFFEE,-5.50,994.50\n".utf8)
    try await firstStore.stagePending(file, data: bytes)
    // Same bytes on disk
    let read = try Data(contentsOf: stagingPath)
    #expect(read == bytes)
    // New store instance reads the index back
    let secondStore = try ImportStagingStore(directory: dir)
    let pending = try await secondStore.pendingFiles()
    #expect(pending.count == 1)
    #expect(pending[0].id == id)
    #expect(pending[0].detectedHeaders == ["date", "amount", "description", "balance"])
  }

  @Test("stageFailed persists the failed-file record with offending row")
  func stageFailedRoundTrip() async throws {
    let dir = tempDirectory()
    defer { cleanup(dir) }
    let store = try ImportStagingStore(directory: dir)
    let id = UUID()
    let path = await store.stagingPath(for: id)
    let file = FailedImportFile(
      id: id,
      originalFilename: "bad.csv",
      stagingPath: path,
      error: "invalid date: foo",
      offendingRow: ["foo", "bar"],
      offendingRowIndex: 3,
      parsedAt: Date())
    try await store.stageFailed(file, data: Data("hi".utf8))
    let failed = try await store.failedFiles()
    #expect(failed.count == 1)
    #expect(failed[0].offendingRow == ["foo", "bar"])
    #expect(failed[0].offendingRowIndex == 3)
  }

  @Test("dismiss removes the record and deletes the file on disk")
  func dismissPendingRemovesFromIndexAndDisk() async throws {
    let dir = tempDirectory()
    defer { cleanup(dir) }
    let store = try ImportStagingStore(directory: dir)
    let id = UUID()
    let path = await store.stagingPath(for: id)
    let file = PendingSetupFile(
      id: id, originalFilename: "x", stagingPath: path,
      securityScopedBookmark: nil, detectedParserIdentifier: nil,
      detectedHeaders: [], parsedAt: Date(), sourceBookmark: nil)
    try await store.stagePending(file, data: Data("hi".utf8))
    try await store.dismiss(pendingId: id)
    let pending = try await store.pendingFiles()
    #expect(pending.isEmpty)
    #expect(FileManager.default.fileExists(atPath: path.path) == false)
  }

  @Test("dismiss of an unknown id throws notFound")
  func dismissUnknownIdThrows() async throws {
    let dir = tempDirectory()
    defer { cleanup(dir) }
    let store = try ImportStagingStore(directory: dir)
    let id = UUID()
    await #expect(throws: ImportStagingStore.StagingError.notFound(id: id)) {
      try await store.dismiss(pendingId: id)
    }
  }

  @Test("stagePending is idempotent when called with the same id twice")
  func stagePendingIdempotent() async throws {
    let dir = tempDirectory()
    defer { cleanup(dir) }
    let store = try ImportStagingStore(directory: dir)
    let id = UUID()
    let path = await store.stagingPath(for: id)
    let first = PendingSetupFile(
      id: id, originalFilename: "a.csv", stagingPath: path,
      securityScopedBookmark: nil, detectedParserIdentifier: nil,
      detectedHeaders: ["date"], parsedAt: Date(), sourceBookmark: nil)
    try await store.stagePending(first, data: Data("one".utf8))
    var second = first
    second.detectedHeaders = ["date", "amount"]
    try await store.stagePending(second, data: Data("two".utf8))
    let pending = try await store.pendingFiles()
    #expect(pending.count == 1)
    #expect(pending[0].detectedHeaders == ["date", "amount"])
    #expect(try Data(contentsOf: path) == Data("two".utf8))
  }

  @Test("data(for:) returns the bytes of a previously-staged pending file")
  func dataForReturnsBytes() async throws {
    let dir = tempDirectory()
    defer { cleanup(dir) }
    let store = try ImportStagingStore(directory: dir)
    let id = UUID()
    let path = await store.stagingPath(for: id)
    let bytes = Data("Date,Description,Amount,Balance\n".utf8)
    let file = PendingSetupFile(
      id: id, originalFilename: "a.csv", stagingPath: path,
      securityScopedBookmark: nil, detectedParserIdentifier: nil,
      detectedHeaders: [], parsedAt: Date(), sourceBookmark: nil)
    try await store.stagePending(file, data: bytes)
    let loaded = try await store.data(for: id)
    #expect(loaded == bytes)
  }
}
