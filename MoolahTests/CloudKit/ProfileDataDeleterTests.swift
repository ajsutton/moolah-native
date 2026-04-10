import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("ProfileDataDeleter")
struct ProfileDataDeleterTests {
  @Test("deletes all data for a profile without affecting other profiles")
  @MainActor
  func testDeletesOnlyTargetProfile() throws {
    let container = try TestModelContainer.create()
    let context = container.mainContext

    let profileA = UUID()
    let profileB = UUID()

    // Seed data for both profiles
    context.insert(CategoryRecord(profileId: profileA, name: "Cat A"))
    context.insert(CategoryRecord(profileId: profileB, name: "Cat B"))
    context.insert(
      AccountRecord(
        profileId: profileA, name: "Account A", type: "bank", currencyCode: "AUD"))
    context.insert(
      AccountRecord(
        profileId: profileB, name: "Account B", type: "bank", currencyCode: "AUD"))
    context.insert(
      TransactionRecord(
        profileId: profileA, type: "expense", date: Date(), amount: -500, currencyCode: "AUD"))
    context.insert(
      TransactionRecord(
        profileId: profileB, type: "income", date: Date(), amount: 1000, currencyCode: "AUD"))
    context.insert(
      EarmarkRecord(
        profileId: profileA, name: "Earmark A", currencyCode: "AUD"))
    context.insert(
      EarmarkRecord(
        profileId: profileB, name: "Earmark B", currencyCode: "AUD"))
    try context.save()

    // Delete profile A's data
    let deleter = ProfileDataDeleter(modelContext: context)
    deleter.deleteAllData(for: profileA)

    // Profile B's data should remain
    let categories = try context.fetch(FetchDescriptor<CategoryRecord>())
    #expect(categories.count == 1)
    #expect(categories[0].name == "Cat B")

    let accounts = try context.fetch(FetchDescriptor<AccountRecord>())
    #expect(accounts.count == 1)
    #expect(accounts[0].name == "Account B")

    let transactions = try context.fetch(FetchDescriptor<TransactionRecord>())
    #expect(transactions.count == 1)
    #expect(transactions[0].amount == 1000)

    let earmarks = try context.fetch(FetchDescriptor<EarmarkRecord>())
    #expect(earmarks.count == 1)
    #expect(earmarks[0].name == "Earmark B")
  }
}
