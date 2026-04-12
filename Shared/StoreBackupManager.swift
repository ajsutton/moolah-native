#if os(macOS)
  import CoreData
  import Foundation
  import OSLog

  @MainActor
  final class StoreBackupManager {
    private let backupDirectory: URL
    private let retentionDays: Int
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "com.moolah.app", category: "Backup")

    private static let dateFormatter: DateFormatter = {
      let f = DateFormatter()
      f.dateFormat = "yyyy-MM-dd"
      return f
    }()

    init(
      backupDirectory: URL = URL.applicationSupportDirectory.appending(path: "Moolah/Backups"),
      retentionDays: Int = 7,
      fileManager: FileManager = .default
    ) {
      self.backupDirectory = backupDirectory
      self.retentionDays = retentionDays
      self.fileManager = fileManager
    }

    /// Backs up a store file if today's backup doesn't already exist.
    func backupStore(at storeURL: URL, profileId: UUID) throws {
      guard !hasBackupForToday(profileId: profileId) else {
        logger.debug("Backup already exists for today, skipping \(profileId)")
        return
      }

      let profileDir = backupDirectory.appending(path: profileId.uuidString)
      try fileManager.createDirectory(at: profileDir, withIntermediateDirectories: true)

      let today = Self.dateFormatter.string(from: Date())
      let backupURL = profileDir.appending(path: "\(today).store")

      let coordinator = NSPersistentStoreCoordinator(managedObjectModel: NSManagedObjectModel())
      try coordinator.replacePersistentStore(
        at: backupURL,
        withPersistentStoreFrom: storeURL,
        type: .sqlite
      )
      logger.info("Backed up profile \(profileId) to \(backupURL.lastPathComponent)")
    }

    func hasBackupForToday(profileId: UUID) -> Bool {
      let profileDir = backupDirectory.appending(path: profileId.uuidString)
      let today = Self.dateFormatter.string(from: Date())
      let backupURL = profileDir.appending(path: "\(today).store")
      return fileManager.fileExists(atPath: backupURL.path())
    }

    func pruneBackups(profileId: UUID) {
      let profileDir = backupDirectory.appending(path: profileId.uuidString)
      guard let files = try? fileManager.contentsOfDirectory(atPath: profileDir.path()) else {
        return
      }

      let storeFiles = files.filter { $0.hasSuffix(".store") }.sorted().reversed()
      let toDelete = Array(storeFiles.dropFirst(retentionDays))
      for filename in toDelete {
        let fileURL = profileDir.appending(path: filename)
        try? fileManager.removeItem(at: fileURL)
        logger.debug("Pruned old backup: \(filename)")
      }
    }

    func performDailyBackup(profiles: [Profile], containerManager: ProfileContainerManager) {
      let cloudProfiles = profiles.filter { $0.backendType == .cloudKit }
      for profile in cloudProfiles {
        do {
          let container = try containerManager.container(for: profile.id)
          guard let storeURL = container.configurations.first?.url else {
            logger.warning("No store URL for profile \(profile.id)")
            continue
          }
          try backupStore(at: storeURL, profileId: profile.id)
          pruneBackups(profileId: profile.id)
        } catch {
          logger.error("Backup failed for profile \(profile.id): \(error.localizedDescription)")
        }
      }
    }
  }
#endif
