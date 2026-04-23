import Foundation
import Testing

@testable import Moolah

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
