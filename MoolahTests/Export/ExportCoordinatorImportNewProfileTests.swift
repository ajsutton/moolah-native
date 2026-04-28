import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("ExportCoordinator.importNewProfileFromFile")
@MainActor
struct ExportCoordinatorImportNewProfileTests {

  private let instrument = Instrument.defaultTestInstrument

  private func makeSeededBackend() async throws -> CloudKitBackend {
    let (backend, _) = try TestBackend.create(instrument: instrument)

    let checking = try await backend.accounts.create(
      Account(name: "Checking", type: .bank, instrument: instrument),
      openingBalance: InstrumentAmount(quantity: dec("500.00"), instrument: instrument)
    )

    let food = try await backend.categories.create(Category(name: "Food"))

    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "Employer",
        legs: [
          TransactionLeg(
            accountId: checking.id, instrument: instrument,
            quantity: dec("1000.00"), type: .income
          )
        ]
      )
    )

    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "Cafe",
        legs: [
          TransactionLeg(
            accountId: checking.id, instrument: instrument,
            quantity: dec("-12.50"), type: .expense,
            categoryId: food.id
          )
        ]
      )
    )

    return backend
  }

  private func makeTempFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("moolah-test-\(UUID().uuidString).json")
  }

  private func makeProfileStore(containerManager: ProfileContainerManager) throws -> ProfileStore {
    let defaults = try #require(UserDefaults(suiteName: "test-\(UUID().uuidString)"))
    return ProfileStore(defaults: defaults, containerManager: containerManager)
  }

  // MARK: - Happy path

  @Test("importNewProfileFromFile creates a profile with the expected entity counts")
  func happyPathEntityCounts() async throws {
    let backend = try await makeSeededBackend()
    let tempURL = makeTempFileURL()
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let sourceProfile = Profile(
      label: "Source Profile",
      currencyCode: instrument.id,
      financialYearStartMonth: 7
    )
    let exportCoordinator = ExportCoordinator()
    try await exportCoordinator.exportToFile(
      url: tempURL,
      backend: backend,
      profile: sourceProfile
    )

    let containerManager = try ProfileContainerManager.forTesting()
    let profileStore = try makeProfileStore(containerManager: containerManager)

    let newProfileId = try await exportCoordinator.importNewProfileFromFile(
      url: tempURL,
      profileStore: profileStore,
      containerManager: containerManager,
      syncCoordinator: nil
    )

    // Profile was registered in profileStore
    let registeredProfile = try #require(profileStore.profiles.first { $0.id == newProfileId })
    #expect(registeredProfile.label == "Source Profile")
    #expect(registeredProfile.currencyCode == instrument.id)
    #expect(registeredProfile.financialYearStartMonth == 7)

    // Data was imported into the container
    let container = try containerManager.container(for: newProfileId)
    let freshDatabase = try ProfileDatabase.openInMemory()
    let freshBackend = CloudKitBackend(
      modelContainer: container,
      database: freshDatabase,
      instrument: instrument,
      profileLabel: registeredProfile.label,
      conversionService: FixedConversionService(),
      instrumentRegistry: CloudKitInstrumentRegistryRepository(modelContainer: container)
    )

    let accounts = try await freshBackend.accounts.fetchAll()
    // 1 account (opening balance creates a transaction, not extra account)
    #expect(accounts.count == 1)
    #expect(accounts.first?.name == "Checking")

    let categories = try await freshBackend.categories.fetchAll()
    #expect(categories.count == 1)

    // 3 transactions: opening balance + income + expense
    let txnPage = try await freshBackend.transactions.fetch(
      filter: TransactionFilter(), page: 0, pageSize: 100
    )
    #expect(txnPage.transactions.count == 3)
  }

  // MARK: - Rollback on failure

  @Test("importNewProfileFromFile rolls back profile and store when import fails")
  func rollbackOnImportFailure() async throws {
    // Write a file that passes JSON decode but has an unsupported version so
    // the import throws after profileStore.addProfile has already been called.
    let exported = ExportedData(
      version: 99,
      exportedAt: Date(),
      profileLabel: "Bad Version Profile",
      currencyCode: "AUD",
      financialYearStartMonth: 1,
      accounts: [],
      categories: [],
      earmarks: [],
      earmarkBudgets: [:],
      transactions: [],
      investmentValues: [:]
    )
    let badURL = makeTempFileURL()
    defer { try? FileManager.default.removeItem(at: badURL) }
    let data = try JSONEncoder.exportEncoder.encode(exported)
    try data.write(to: badURL)

    let containerManager = try ProfileContainerManager.forTesting()
    let profileStore = try makeProfileStore(containerManager: containerManager)

    // Intercept the profile ID that was registered mid-flight so we can verify
    // the container cache is also cleared after rollback.
    var capturedProfileId: UUID?
    profileStore.onProfileChanged = { id in capturedProfileId = id }

    let coordinator = ExportCoordinator()
    await #expect(throws: ExportError.self) {
      _ = try await coordinator.importNewProfileFromFile(
        url: badURL,
        profileStore: profileStore,
        containerManager: containerManager,
        syncCoordinator: nil
      )
    }

    // Profile must have been removed from profileStore (rollback succeeded)
    #expect(profileStore.profiles.isEmpty)

    // Container cache must also have been cleared (no double-deleteStore bug)
    let profileId = try #require(capturedProfileId)
    #expect(!containerManager.hasContainer(for: profileId))
  }
}
