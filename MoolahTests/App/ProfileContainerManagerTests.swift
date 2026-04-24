import Foundation
import SwiftData
import Testing

@testable import Moolah

// Serialised because testContainerUsesScopedStoreURL mutates
// `URL.moolahApplicationSupportOverride`, a `nonisolated(unsafe)` static.
// The other tests in this suite use the in-memory forTesting() path and
// would be safe to parallelise, but the suite is small enough that
// serialisation is a cheap way to eliminate the override-leak hazard.
@Suite("ProfileContainerManager", .serialized)
struct ProfileContainerManagerTests {
  @Test("creates index container with ProfileRecord schema only")
  @MainActor
  func testIndexContainerSchema() throws {
    let manager = try ProfileContainerManager.forTesting()
    let context = ModelContext(manager.indexContainer)
    let descriptor = FetchDescriptor<ProfileRecord>()
    let profiles = try context.fetch(descriptor)
    #expect(profiles.isEmpty)
  }

  @Test("creates per-profile container with data schema only")
  @MainActor
  func testProfileContainerSchema() throws {
    let manager = try ProfileContainerManager.forTesting()
    let profileId = UUID()
    let container = try manager.container(for: profileId)
    let context = ModelContext(container)
    let accounts = try context.fetch(FetchDescriptor<AccountRecord>())
    #expect(accounts.isEmpty)
    let transactions = try context.fetch(FetchDescriptor<TransactionRecord>())
    #expect(transactions.isEmpty)
  }

  @Test("returns same container for same profile ID")
  @MainActor
  func testContainerCaching() throws {
    let manager = try ProfileContainerManager.forTesting()
    let profileId = UUID()
    let container1 = try manager.container(for: profileId)
    let container2 = try manager.container(for: profileId)
    #expect(container1 === container2)
  }

  @Test("returns different containers for different profiles")
  @MainActor
  func testContainerIsolation() throws {
    let manager = try ProfileContainerManager.forTesting()
    let container1 = try manager.container(for: UUID())
    let container2 = try manager.container(for: UUID())
    #expect(container1 !== container2)
  }

  @Test("deleteStore removes container from cache")
  @MainActor
  func testDeleteStore() throws {
    let manager = try ProfileContainerManager.forTesting()
    let profileId = UUID()
    let container1 = try manager.container(for: profileId)
    manager.deleteStore(for: profileId)
    let container2 = try manager.container(for: profileId)
    #expect(container1 !== container2)
  }

  @Test("configures per-profile store URL under the scoped Application Support root")
  @MainActor
  func testContainerUsesScopedStoreURL() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    URL.moolahApplicationSupportOverride = root
    defer { URL.moolahApplicationSupportOverride = nil }

    let indexSchema = Schema([ProfileRecord.self])
    let indexConfig = ModelConfiguration(isStoredInMemoryOnly: true)
    let indexContainer = try ModelContainer(for: indexSchema, configurations: [indexConfig])
    let dataSchema = Schema([
      AccountRecord.self,
      TransactionRecord.self,
      TransactionLegRecord.self,
      InstrumentRecord.self,
      CategoryRecord.self,
      EarmarkRecord.self,
      EarmarkBudgetItemRecord.self,
      InvestmentValueRecord.self,
      CSVImportProfileRecord.self,
      ImportRuleRecord.self,
    ])

    let manager = ProfileContainerManager(
      indexContainer: indexContainer,
      dataSchema: dataSchema,
      inMemory: false
    )

    let profileId = UUID()
    let container = try manager.container(for: profileId)

    let envSubdir = CloudKitEnvironment.resolved().storageSubdirectory
    let expectedStore =
      root
      .appending(path: envSubdir)
      .appending(path: "Moolah-\(profileId.uuidString).store")
    let actualURL = container.configurations.first?.url
    #expect(actualURL?.standardizedFileURL == expectedStore.standardizedFileURL)

    // Env subdir must have been created on demand by the scoped helper.
    let envDir = root.appending(path: envSubdir)
    #expect(FileManager.default.fileExists(atPath: envDir.path()))
  }
}
