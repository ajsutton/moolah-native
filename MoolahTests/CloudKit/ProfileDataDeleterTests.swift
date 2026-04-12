import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("ProfileDataDeleter")
struct ProfileDataDeleterTests {
  @Test("deletes ProfileRecord from index store")
  @MainActor
  func testDeleteProfileRecord() throws {
    let schema = Schema([ProfileRecord.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [config])
    let context = ModelContext(container)

    let profileId = UUID()
    let record = ProfileRecord(id: profileId, label: "Test", currencyCode: "AUD")
    context.insert(record)
    try context.save()

    let deleter = ProfileDataDeleter(modelContext: context)
    deleter.deleteProfileRecord(for: profileId)

    let descriptor = FetchDescriptor<ProfileRecord>()
    let remaining = try context.fetch(descriptor)
    #expect(remaining.isEmpty)
  }

  @Test("does not delete other profiles")
  @MainActor
  func testDeleteOnlyTargetProfile() throws {
    let schema = Schema([ProfileRecord.self])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [config])
    let context = ModelContext(container)

    let profileA = UUID()
    let profileB = UUID()
    context.insert(ProfileRecord(id: profileA, label: "A", currencyCode: "AUD"))
    context.insert(ProfileRecord(id: profileB, label: "B", currencyCode: "AUD"))
    try context.save()

    let deleter = ProfileDataDeleter(modelContext: context)
    deleter.deleteProfileRecord(for: profileA)

    let descriptor = FetchDescriptor<ProfileRecord>()
    let remaining = try context.fetch(descriptor)
    #expect(remaining.count == 1)
    #expect(remaining[0].label == "B")
  }
}
