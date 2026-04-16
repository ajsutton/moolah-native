import Foundation
import Testing

@testable import Moolah

@Suite("SessionManager Automation Extensions")
@MainActor
struct SessionManagerAutomationTests {
  private func makeManager() throws -> SessionManager {
    let containerManager = try ProfileContainerManager.forTesting()
    return SessionManager(containerManager: containerManager)
  }

  private func makeProfile(label: String = "Personal") -> Profile {
    Profile(
      label: label,
      backendType: .cloudKit,
      currencyCode: "AUD",
      financialYearStartMonth: 7
    )
  }

  @Test("session(named:) finds session by exact profile name")
  func findSessionByProfileName() throws {
    let manager = try makeManager()
    let profile = makeProfile(label: "Personal")
    _ = manager.session(for: profile)

    let found = manager.session(named: "Personal")

    #expect(found != nil)
    #expect(found?.profile.id == profile.id)
  }

  @Test("session(named:) finds session case-insensitively")
  func findSessionByProfileNameCaseInsensitive() throws {
    let manager = try makeManager()
    let profile = makeProfile(label: "Personal")
    _ = manager.session(for: profile)

    let found = manager.session(named: "personal")

    #expect(found != nil)
    #expect(found?.profile.id == profile.id)
  }

  @Test("session(named:) returns nil when no session matches")
  func findSessionByProfileNameReturnsNilWhenNotFound() throws {
    let manager = try makeManager()
    let profile = makeProfile(label: "Personal")
    _ = manager.session(for: profile)

    let found = manager.session(named: "Business")

    #expect(found == nil)
  }

  @Test("session(forID:) finds session by UUID")
  func findSessionByUUID() throws {
    let manager = try makeManager()
    let profile = makeProfile()
    _ = manager.session(for: profile)

    let found = manager.session(forID: profile.id)

    #expect(found != nil)
    #expect(found?.profile.id == profile.id)
  }

  @Test("session(forID:) returns nil for unknown UUID")
  func findSessionByUUIDReturnsNilWhenNotFound() throws {
    let manager = try makeManager()

    let found = manager.session(forID: UUID())

    #expect(found == nil)
  }

  @Test("openProfiles returns all sessions")
  func openProfilesReturnsAllSessions() throws {
    let manager = try makeManager()
    let profile1 = makeProfile(label: "Personal")
    let profile2 = makeProfile(label: "Business")
    _ = manager.session(for: profile1)
    _ = manager.session(for: profile2)

    let open = manager.openProfiles

    #expect(open.count == 2)
    let ids = Set(open.map(\.profile.id))
    #expect(ids.contains(profile1.id))
    #expect(ids.contains(profile2.id))
  }
}

@Suite("AutomationService Profile Operations")
@MainActor
struct AutomationServiceProfileTests {
  private func makeService() throws -> (AutomationService, SessionManager) {
    let containerManager = try ProfileContainerManager.forTesting()
    let sessionManager = SessionManager(containerManager: containerManager)
    let service = AutomationService(sessionManager: sessionManager)
    return (service, sessionManager)
  }

  private func makeProfile(label: String = "Personal") -> Profile {
    Profile(
      label: label,
      backendType: .cloudKit,
      currencyCode: "AUD",
      financialYearStartMonth: 7
    )
  }

  @Test("resolveSession finds session by name")
  func resolveByName() throws {
    let (service, sessionManager) = try makeService()
    let profile = makeProfile(label: "Personal")
    _ = sessionManager.session(for: profile)

    let session = try service.resolveSession(for: "Personal")

    #expect(session.profile.id == profile.id)
  }

  @Test("resolveSession finds session by UUID string")
  func resolveByUUID() throws {
    let (service, sessionManager) = try makeService()
    let profile = makeProfile(label: "Personal")
    _ = sessionManager.session(for: profile)

    let session = try service.resolveSession(for: profile.id.uuidString)

    #expect(session.profile.id == profile.id)
  }

  @Test("resolveSession throws when profile not found")
  func throwsWhenNotFound() throws {
    let (service, _) = try makeService()

    #expect(throws: AutomationError.self) {
      try service.resolveSession(for: "NonExistent")
    }
  }

  @Test("listOpenProfiles returns all open profiles")
  func listOpenProfiles() throws {
    let (service, sessionManager) = try makeService()
    let profile1 = makeProfile(label: "Personal")
    let profile2 = makeProfile(label: "Business")
    _ = sessionManager.session(for: profile1)
    _ = sessionManager.session(for: profile2)

    let profiles = service.listOpenProfiles()

    #expect(profiles.count == 2)
    let labels = Set(profiles.map(\.label))
    #expect(labels.contains("Personal"))
    #expect(labels.contains("Business"))
  }
}

// MARK: - Account Operations

@Suite("AutomationService Account Operations")
@MainActor
struct AutomationServiceAccountTests {
  private func makeServiceWithSession() async throws -> (AutomationService, ProfileSession) {
    let containerManager = try ProfileContainerManager.forTesting()
    let sessionManager = SessionManager(containerManager: containerManager)
    let profile = Profile(
      label: "Test",
      backendType: .cloudKit,
      currencyCode: "AUD",
      financialYearStartMonth: 7
    )
    let session = sessionManager.session(for: profile)
    await session.accountStore.load()
    let service = AutomationService(sessionManager: sessionManager)
    return (service, session)
  }

  @Test("createAccount creates and lists accounts")
  func createAndListAccounts() async throws {
    let (service, _) = try await makeServiceWithSession()

    let account = try await service.createAccount(
      profileIdentifier: "Test",
      name: "Savings",
      type: .bank
    )

    #expect(account.name == "Savings")
    #expect(account.type == .bank)
    #expect(account.positions.isEmpty)

    let accounts = try service.listAccounts(profileIdentifier: "Test")
    #expect(accounts.count == 1)
    #expect(accounts.first?.name == "Savings")
  }

  @Test("resolveAccount finds account by name case-insensitively")
  func resolveAccountByNameCaseInsensitive() async throws {
    let (service, _) = try await makeServiceWithSession()
    _ = try await service.createAccount(
      profileIdentifier: "Test",
      name: "My Savings",
      type: .bank
    )

    let resolved = try service.resolveAccount(named: "my savings", profileIdentifier: "Test")
    #expect(resolved.name == "My Savings")
  }

  @Test("resolveAccount throws when not found")
  func resolveAccountNotFoundThrows() async throws {
    let (service, _) = try await makeServiceWithSession()

    #expect(throws: AutomationError.self) {
      try service.resolveAccount(named: "NonExistent", profileIdentifier: "Test")
    }
  }

  @Test("resolveAccount finds account by UUID")
  func resolveAccountByUUID() async throws {
    let (service, _) = try await makeServiceWithSession()
    let created = try await service.createAccount(
      profileIdentifier: "Test",
      name: "Checking",
      type: .bank
    )

    let resolved = try service.resolveAccount(id: created.id, profileIdentifier: "Test")
    #expect(resolved.name == "Checking")
  }

  @Test("getNetWorth returns sum of current and investment accounts")
  func getNetWorth() async throws {
    let (service, session) = try await makeServiceWithSession()
    let instrument = session.profile.instrument

    // Create a bank account with a balance
    let bankAccount = Account(
      name: "Bank",
      type: .bank,
      instrument: instrument,
      position: 0
    )
    let openingBalance = InstrumentAmount(quantity: 1000, instrument: instrument)
    _ = try await session.accountStore.create(bankAccount, openingBalance: openingBalance)

    // Reload to pick up positions computed from the opening balance transaction
    await session.accountStore.load()

    let netWorth = try service.getNetWorth(profileIdentifier: "Test")
    #expect(netWorth.quantity == 1000)
  }

  @Test("updateAccount changes account name")
  func updateAccountName() async throws {
    let (service, _) = try await makeServiceWithSession()
    let created = try await service.createAccount(
      profileIdentifier: "Test",
      name: "Old Name",
      type: .bank
    )

    let updated = try await service.updateAccount(
      profileIdentifier: "Test",
      accountId: created.id,
      name: "New Name"
    )

    #expect(updated.name == "New Name")
  }

  @Test("deleteAccount removes account")
  func deleteAccount() async throws {
    let (service, _) = try await makeServiceWithSession()
    let created = try await service.createAccount(
      profileIdentifier: "Test",
      name: "ToDelete",
      type: .bank
    )

    try await service.deleteAccount(profileIdentifier: "Test", accountId: created.id)

    let accounts = try service.listAccounts(profileIdentifier: "Test")
    #expect(accounts.isEmpty)
  }
}

// MARK: - Transaction Operations

@Suite("AutomationService Transaction Operations")
@MainActor
struct AutomationServiceTransactionTests {
  private func makeServiceWithSession() async throws -> (AutomationService, ProfileSession) {
    let containerManager = try ProfileContainerManager.forTesting()
    let sessionManager = SessionManager(containerManager: containerManager)
    let profile = Profile(
      label: "Test",
      backendType: .cloudKit,
      currencyCode: "AUD",
      financialYearStartMonth: 7
    )
    let session = sessionManager.session(for: profile)
    await session.accountStore.load()
    await session.categoryStore.load()
    await session.earmarkStore.load()
    let service = AutomationService(sessionManager: sessionManager)
    return (service, session)
  }

  @Test("createTransaction creates a single-leg transaction")
  func createSingleLegTransaction() async throws {
    let (service, _) = try await makeServiceWithSession()

    // Create an account first
    _ = try await service.createAccount(
      profileIdentifier: "Test",
      name: "Checking",
      type: .bank
    )

    let transaction = try await service.createTransaction(
      profileIdentifier: "Test",
      payee: "Grocery Store",
      date: Date(),
      legs: [
        AutomationService.LegSpec(
          accountName: "Checking",
          amount: -50,
          categoryName: nil,
          earmarkName: nil
        )
      ],
      notes: "Weekly shopping"
    )

    #expect(transaction.payee == "Grocery Store")
    #expect(transaction.notes == "Weekly shopping")
    #expect(transaction.legs.count == 1)
    #expect(transaction.legs.first?.quantity == -50)
    #expect(transaction.legs.first?.type == .expense)
  }

  @Test("listTransactions returns created transactions")
  func listTransactions() async throws {
    let (service, _) = try await makeServiceWithSession()

    _ = try await service.createAccount(
      profileIdentifier: "Test",
      name: "Checking",
      type: .bank
    )

    _ = try await service.createTransaction(
      profileIdentifier: "Test",
      payee: "Store A",
      date: Date(),
      legs: [
        AutomationService.LegSpec(
          accountName: "Checking",
          amount: -25,
          categoryName: nil,
          earmarkName: nil
        )
      ]
    )

    let transactions = try await service.listTransactions(profileIdentifier: "Test")
    #expect(transactions.count == 1)
    #expect(transactions.first?.payee == "Store A")
  }

  @Test("createTransaction with positive amount creates income")
  func createIncomeTransaction() async throws {
    let (service, _) = try await makeServiceWithSession()

    _ = try await service.createAccount(
      profileIdentifier: "Test",
      name: "Checking",
      type: .bank
    )

    let transaction = try await service.createTransaction(
      profileIdentifier: "Test",
      payee: "Employer",
      date: Date(),
      legs: [
        AutomationService.LegSpec(
          accountName: "Checking",
          amount: 3000,
          categoryName: nil,
          earmarkName: nil
        )
      ]
    )

    #expect(transaction.legs.first?.type == .income)
    #expect(transaction.legs.first?.quantity == 3000)
  }
}

// MARK: - Earmark Operations

@Suite("AutomationService Earmark Operations")
@MainActor
struct AutomationServiceEarmarkTests {
  private func makeServiceWithSession() async throws -> (AutomationService, ProfileSession) {
    let containerManager = try ProfileContainerManager.forTesting()
    let sessionManager = SessionManager(containerManager: containerManager)
    let profile = Profile(
      label: "Test",
      backendType: .cloudKit,
      currencyCode: "AUD",
      financialYearStartMonth: 7
    )
    let session = sessionManager.session(for: profile)
    await session.earmarkStore.load()
    let service = AutomationService(sessionManager: sessionManager)
    return (service, session)
  }

  @Test("createEarmark creates and lists earmarks")
  func createAndListEarmarks() async throws {
    let (service, _) = try await makeServiceWithSession()

    let earmark = try await service.createEarmark(
      profileIdentifier: "Test",
      name: "Holiday Fund",
      targetAmount: 5000
    )

    #expect(earmark.name == "Holiday Fund")
    #expect(earmark.savingsGoal?.quantity == 5000)

    let earmarks = try service.listEarmarks(profileIdentifier: "Test")
    #expect(earmarks.count == 1)
    #expect(earmarks.first?.name == "Holiday Fund")
  }

  @Test("resolveEarmark finds earmark case-insensitively")
  func resolveEarmarkCaseInsensitive() async throws {
    let (service, _) = try await makeServiceWithSession()

    _ = try await service.createEarmark(
      profileIdentifier: "Test",
      name: "Emergency Fund"
    )

    let resolved = try service.resolveEarmark(named: "emergency fund", profileIdentifier: "Test")
    #expect(resolved.name == "Emergency Fund")
  }

  @Test("resolveEarmark throws when not found")
  func resolveEarmarkNotFound() async throws {
    let (service, _) = try await makeServiceWithSession()

    #expect(throws: AutomationError.self) {
      try service.resolveEarmark(named: "NonExistent", profileIdentifier: "Test")
    }
  }
}

// MARK: - Category Operations

@Suite("AutomationService Category Operations")
@MainActor
struct AutomationServiceCategoryTests {
  private func makeServiceWithSession() async throws -> (AutomationService, ProfileSession) {
    let containerManager = try ProfileContainerManager.forTesting()
    let sessionManager = SessionManager(containerManager: containerManager)
    let profile = Profile(
      label: "Test",
      backendType: .cloudKit,
      currencyCode: "AUD",
      financialYearStartMonth: 7
    )
    let session = sessionManager.session(for: profile)
    await session.categoryStore.load()
    let service = AutomationService(sessionManager: sessionManager)
    return (service, session)
  }

  @Test("createCategory creates and lists categories")
  func createAndListCategories() async throws {
    let (service, _) = try await makeServiceWithSession()

    let category = try await service.createCategory(
      profileIdentifier: "Test",
      name: "Food",
      parentName: nil
    )

    #expect(category.name == "Food")
    #expect(category.parentId == nil)

    let categories = try service.listCategories(profileIdentifier: "Test")
    #expect(categories.count == 1)
    #expect(categories.first?.name == "Food")
  }

  @Test("resolveCategory finds category by name case-insensitively")
  func resolveCategoryByName() async throws {
    let (service, _) = try await makeServiceWithSession()

    _ = try await service.createCategory(
      profileIdentifier: "Test",
      name: "Transport",
      parentName: nil
    )

    let resolved = try service.resolveCategory(named: "transport", profileIdentifier: "Test")
    #expect(resolved.name == "Transport")
  }

  @Test("resolveCategory throws when not found")
  func resolveCategoryNotFound() async throws {
    let (service, _) = try await makeServiceWithSession()

    #expect(throws: AutomationError.self) {
      try service.resolveCategory(named: "NonExistent", profileIdentifier: "Test")
    }
  }

  @Test("createCategory with parent creates subcategory")
  func createSubcategory() async throws {
    let (service, _) = try await makeServiceWithSession()

    let parent = try await service.createCategory(
      profileIdentifier: "Test",
      name: "Food",
      parentName: nil
    )

    let child = try await service.createCategory(
      profileIdentifier: "Test",
      name: "Groceries",
      parentName: "Food"
    )

    #expect(child.parentId == parent.id)
  }
}
