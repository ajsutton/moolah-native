import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class ProfileContainerManager {
  let indexContainer: ModelContainer
  private let dataSchema: Schema
  private let cloudKitDatabase: ModelConfiguration.CloudKitDatabase
  private let inMemory: Bool
  private var containers: [UUID: ModelContainer] = [:]

  init(
    indexContainer: ModelContainer,
    dataSchema: Schema,
    cloudKitDatabase: ModelConfiguration.CloudKitDatabase = .automatic,
    inMemory: Bool = false
  ) {
    self.indexContainer = indexContainer
    self.dataSchema = dataSchema
    self.cloudKitDatabase = cloudKitDatabase
    self.inMemory = inMemory
  }

  func container(for profileId: UUID) throws -> ModelContainer {
    if let existing = containers[profileId] {
      return existing
    }
    let config: ModelConfiguration
    if inMemory {
      config = ModelConfiguration(isStoredInMemoryOnly: true)
    } else {
      let url = URL.applicationSupportDirectory
        .appending(path: "Moolah-\(profileId.uuidString).store")
      config = ModelConfiguration(url: url, cloudKitDatabase: cloudKitDatabase)
    }
    let container = try ModelContainer(for: dataSchema, configurations: [config])
    containers[profileId] = container
    return container
  }

  func deleteStore(for profileId: UUID) {
    containers.removeValue(forKey: profileId)

    guard !inMemory else { return }

    let basePath = "Moolah-\(profileId.uuidString).store"
    let baseURL = URL.applicationSupportDirectory.appending(path: basePath)
    let fm = FileManager.default
    for suffix in ["", "-shm", "-wal"] {
      let url = baseURL.deletingLastPathComponent()
        .appending(path: baseURL.lastPathComponent + suffix)
      try? fm.removeItem(at: url)
    }
  }

  /// Creates a test-only manager with in-memory stores.
  static func forTesting() throws -> ProfileContainerManager {
    let indexSchema = Schema([ProfileRecord.self])
    let indexConfig = ModelConfiguration(isStoredInMemoryOnly: true)
    let indexContainer = try ModelContainer(for: indexSchema, configurations: [indexConfig])

    let dataSchema = Schema([
      AccountRecord.self,
      TransactionRecord.self,
      CategoryRecord.self,
      EarmarkRecord.self,
      EarmarkBudgetItemRecord.self,
      InvestmentValueRecord.self,
    ])

    return ProfileContainerManager(
      indexContainer: indexContainer,
      dataSchema: dataSchema,
      inMemory: true
    )
  }
}
