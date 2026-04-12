import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("ProfileContainerManager")
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
}
