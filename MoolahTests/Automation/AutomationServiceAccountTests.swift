import Foundation
import Testing

@testable import Moolah

@Suite("AutomationService Account Operations")
@MainActor
struct AutomationServiceAccountTests {
  private func makeServiceWithSession() async throws -> (AutomationService, ProfileSession) {
    let containerManager = try ProfileContainerManager.forTesting()
    let sessionManager = SessionManager(containerManager: containerManager)
    let profile = Profile(
      label: "Test",
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

    let netWorth = try await service.getNetWorth(profileIdentifier: "Test")
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
      changes: AccountChanges(name: "New Name")
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
