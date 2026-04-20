import Foundation
import OSLog

private let stagingLogger = Logger(
  subsystem: "com.moolah.app", category: "ImportStagingStore")

/// A CSV file that couldn't auto-route and is waiting for the user to confirm
/// the column mapping / target account. Held on disk; not synced. The source
/// bytes are copied into the staging directory so the user can still retry
/// after the original file has been moved / deleted.
struct PendingSetupFile: Codable, Sendable, Hashable, Identifiable {
  var id: UUID
  var originalFilename: String
  var stagingPath: URL
  var securityScopedBookmark: Data?
  var detectedParserIdentifier: String?
  var detectedHeaders: [String]
  var parsedAt: Date
  /// Bookmark to the source file the user originally picked. Used when
  /// `deleteAfterImport` is on and the user wants to retire the source after
  /// a successful import.
  var sourceBookmark: Data?
}

/// A CSV file that failed to parse outright. Held on disk for the user to see
/// in the Failed Files panel with the offending row.
struct FailedImportFile: Codable, Sendable, Hashable, Identifiable {
  var id: UUID
  var originalFilename: String
  var stagingPath: URL
  var error: String
  var offendingRow: [String]?
  var offendingRowIndex: Int?
  var parsedAt: Date
}

/// Actor-isolated JSON-index + file-copy store for pending/failed CSV
/// imports. Device-local; not synced. Lives on disk so the user can quit
/// Moolah and come back to unfinished setup work.
///
/// Layout:
/// ```
/// <directory>/
///   index.json       ← list of PendingSetupFile + FailedImportFile
///   files/
///     <uuid>.csv     ← copy of the original bytes
/// ```
actor ImportStagingStore {

  enum StagingError: Error, Equatable, Sendable {
    case notFound(id: UUID)
  }

  private let indexURL: URL
  private let filesDirectory: URL
  private let fileManager: FileManager

  init(directory: URL, fileManager: FileManager = .default) throws {
    self.indexURL = directory.appendingPathComponent("index.json")
    self.filesDirectory = directory.appendingPathComponent("files", isDirectory: true)
    self.fileManager = fileManager
    try fileManager.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
  }

  /// Compute the canonical on-disk path for a newly-staged file id. Callers
  /// get this first so the `stagingPath` they store in the index matches the
  /// actual file location.
  func stagingPath(for id: UUID) -> URL {
    filesDirectory.appendingPathComponent("\(id.uuidString).csv")
  }

  // MARK: - Pending

  func stagePending(_ file: PendingSetupFile, data: Data) throws {
    try data.write(to: file.stagingPath, options: .atomic)
    var index = try load()
    index.pending.removeAll { $0.id == file.id }  // idempotent re-stage
    index.pending.append(file)
    try save(index)
  }

  func pendingFiles() throws -> [PendingSetupFile] {
    try load().pending
  }

  func dismiss(pendingId: UUID) throws {
    var index = try load()
    if let match = index.pending.first(where: { $0.id == pendingId }) {
      try? fileManager.removeItem(at: match.stagingPath)
    } else {
      throw StagingError.notFound(id: pendingId)
    }
    index.pending.removeAll { $0.id == pendingId }
    try save(index)
  }

  // MARK: - Failed

  func stageFailed(_ file: FailedImportFile, data: Data) throws {
    try data.write(to: file.stagingPath, options: .atomic)
    var index = try load()
    index.failed.removeAll { $0.id == file.id }
    index.failed.append(file)
    try save(index)
  }

  func failedFiles() throws -> [FailedImportFile] {
    try load().failed
  }

  func dismiss(failedId: UUID) throws {
    var index = try load()
    if let match = index.failed.first(where: { $0.id == failedId }) {
      try? fileManager.removeItem(at: match.stagingPath)
    } else {
      throw StagingError.notFound(id: failedId)
    }
    index.failed.removeAll { $0.id == failedId }
    try save(index)
  }

  /// Load the raw bytes of a previously staged pending file — used when the
  /// user confirms the setup and the pipeline re-runs.
  func data(for pendingId: UUID) throws -> Data {
    let index = try load()
    guard let match = index.pending.first(where: { $0.id == pendingId }) else {
      throw StagingError.notFound(id: pendingId)
    }
    return try Data(contentsOf: match.stagingPath)
  }

  /// Load the raw bytes of a previously staged failed file — used for the
  /// Retry action in the Failed Files panel.
  func data(forFailedId failedId: UUID) throws -> Data {
    let index = try load()
    guard let match = index.failed.first(where: { $0.id == failedId }) else {
      throw StagingError.notFound(id: failedId)
    }
    return try Data(contentsOf: match.stagingPath)
  }

  // MARK: - Persistence

  private struct Index: Codable {
    var pending: [PendingSetupFile] = []
    var failed: [FailedImportFile] = []
  }

  private func load() throws -> Index {
    guard fileManager.fileExists(atPath: indexURL.path) else { return Index() }
    let data = try Data(contentsOf: indexURL)
    return try JSONDecoder().decode(Index.self, from: data)
  }

  private func save(_ index: Index) throws {
    let data = try JSONEncoder().encode(index)
    try data.write(to: indexURL, options: .atomic)
  }
}
