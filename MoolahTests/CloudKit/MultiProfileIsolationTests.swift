import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("Multi-Profile Isolation")
struct MultiProfileIsolationTests {
  @Test("two CloudKit backends sharing a container see only their own data")
  @MainActor
  func testProfileIsolation() async throws {
    let container = try TestModelContainer.create()
    let currency = Currency.defaultTestCurrency
    let profileA = UUID()
    let profileB = UUID()

    let backendA = CloudKitBackend(
      modelContainer: container, profileId: profileA, currency: currency, profileLabel: "A")
    let backendB = CloudKitBackend(
      modelContainer: container, profileId: profileB, currency: currency, profileLabel: "B")

    // Create data in profile A
    _ = try await backendA.categories.create(Moolah.Category(name: "Groceries"))
    _ = try await backendA.categories.create(Moolah.Category(name: "Transport"))

    // Create data in profile B
    _ = try await backendB.categories.create(Moolah.Category(name: "Entertainment"))

    // Profile A sees only its categories
    let categoriesA = try await backendA.categories.fetchAll()
    #expect(categoriesA.count == 2)

    // Profile B sees only its category
    let categoriesB = try await backendB.categories.fetchAll()
    #expect(categoriesB.count == 1)
    #expect(categoriesB[0].name == "Entertainment")
  }

  @Test("deleting one profile's data doesn't affect another")
  @MainActor
  func testDeleteIsolation() async throws {
    let container = try TestModelContainer.create()
    let currency = Currency.defaultTestCurrency
    let profileA = UUID()
    let profileB = UUID()

    let backendA = CloudKitBackend(
      modelContainer: container, profileId: profileA, currency: currency, profileLabel: "A")
    let backendB = CloudKitBackend(
      modelContainer: container, profileId: profileB, currency: currency, profileLabel: "B")

    _ = try await backendA.categories.create(Moolah.Category(name: "A-Cat"))
    _ = try await backendB.categories.create(Moolah.Category(name: "B-Cat"))

    // Delete all of profile A's data
    let deleter = ProfileDataDeleter(modelContext: container.mainContext)
    deleter.deleteAllData(for: profileA)

    // Profile A should see nothing
    let categoriesA = try await backendA.categories.fetchAll()
    #expect(categoriesA.isEmpty)

    // Profile B should be unaffected
    let categoriesB = try await backendB.categories.fetchAll()
    #expect(categoriesB.count == 1)
    #expect(categoriesB[0].name == "B-Cat")
  }
}
