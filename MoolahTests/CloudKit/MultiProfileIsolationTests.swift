import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("Multi-Profile Isolation")
struct MultiProfileIsolationTests {
  @Test("two CloudKit backends with separate containers see only their own data")
  @MainActor
  func testProfileIsolation() async throws {
    let (backendA, _) = try TestBackend.create()
    let (backendB, _) = try TestBackend.create()

    _ = try await backendA.categories.create(Moolah.Category(name: "Groceries"))
    _ = try await backendA.categories.create(Moolah.Category(name: "Transport"))
    _ = try await backendB.categories.create(Moolah.Category(name: "Entertainment"))

    let categoriesA = try await backendA.categories.fetchAll()
    #expect(categoriesA.count == 2)

    let categoriesB = try await backendB.categories.fetchAll()
    #expect(categoriesB.count == 1)
    #expect(categoriesB[0].name == "Entertainment")
  }

  @Test("deleting one profile's store doesn't affect another")
  @MainActor
  func testDeleteIsolation() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let profileA = UUID()
    let profileB = UUID()

    let containerA = try manager.container(for: profileA)
    let containerB = try manager.container(for: profileB)

    let backendA = CloudKitBackend(
      modelContainer: containerA, currency: .defaultTestCurrency, profileLabel: "A")
    let backendB = CloudKitBackend(
      modelContainer: containerB, currency: .defaultTestCurrency, profileLabel: "B")

    _ = try await backendA.categories.create(Moolah.Category(name: "A-Cat"))
    _ = try await backendB.categories.create(Moolah.Category(name: "B-Cat"))

    manager.deleteStore(for: profileA)

    let categoriesB = try await backendB.categories.fetchAll()
    #expect(categoriesB.count == 1)
    #expect(categoriesB[0].name == "B-Cat")
  }
}
