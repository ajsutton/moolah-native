import CloudKit
import Foundation
import SwiftData
import Testing

@testable import Moolah

@Suite("ChangeTracker")
@MainActor
struct ChangeTrackerTests {

  @Test func detectsInsertedRecords() throws {
    let container = try TestModelContainer.create()
    let profileId = UUID()
    let syncEngine = ProfileSyncEngine(profileId: profileId, modelContainer: container)
    let tracker = ChangeTracker(syncEngine: syncEngine, modelContainer: container)
    tracker.startTracking()

    // Insert an account
    let context = ModelContext(container)
    let account = AccountRecord(
      id: UUID(), name: "New", type: "bank", position: 0,
      isHidden: false, currencyCode: "AUD"
    )
    context.insert(account)
    try context.save()

    // Tracker should have queued a pending save
    #expect(syncEngine.hasPendingChanges)
  }

  @Test func detectsUpdatedRecords() throws {
    let container = try TestModelContainer.create()
    let profileId = UUID()
    let syncEngine = ProfileSyncEngine(profileId: profileId, modelContainer: container)
    let tracker = ChangeTracker(syncEngine: syncEngine, modelContainer: container)

    // Insert a record first (before tracking starts)
    let accountId = UUID()
    let context = ModelContext(container)
    let account = AccountRecord(
      id: accountId, name: "Old", type: "bank", position: 0,
      isHidden: false, currencyCode: "AUD"
    )
    context.insert(account)
    try context.save()

    tracker.startTracking()

    // Update the record
    let updateContext = ModelContext(container)
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.id == accountId }
    )
    let fetched = try updateContext.fetch(descriptor).first!
    fetched.name = "Updated"
    try updateContext.save()

    #expect(syncEngine.hasPendingChanges)
  }

  @Test func detectsDeletedRecords() throws {
    let container = try TestModelContainer.create()
    let profileId = UUID()
    let syncEngine = ProfileSyncEngine(profileId: profileId, modelContainer: container)
    let tracker = ChangeTracker(syncEngine: syncEngine, modelContainer: container)

    // Insert a record first
    let accountId = UUID()
    let context = ModelContext(container)
    let account = AccountRecord(
      id: accountId, name: "ToDelete", type: "bank", position: 0,
      isHidden: false, currencyCode: "AUD"
    )
    context.insert(account)
    try context.save()

    tracker.startTracking()

    // Delete the record
    let deleteContext = ModelContext(container)
    let descriptor = FetchDescriptor<AccountRecord>(
      predicate: #Predicate { $0.id == accountId }
    )
    let fetched = try deleteContext.fetch(descriptor).first!
    deleteContext.delete(fetched)
    try deleteContext.save()

    #expect(syncEngine.hasPendingChanges)
  }

  @Test func doesNotTrackBeforeStarting() throws {
    let container = try TestModelContainer.create()
    let profileId = UUID()
    let syncEngine = ProfileSyncEngine(profileId: profileId, modelContainer: container)
    _ = ChangeTracker(syncEngine: syncEngine, modelContainer: container)
    // Don't call startTracking()

    let context = ModelContext(container)
    let account = AccountRecord(
      id: UUID(), name: "Ignored", type: "bank", position: 0,
      isHidden: false, currencyCode: "AUD"
    )
    context.insert(account)
    try context.save()

    #expect(!syncEngine.hasPendingChanges)
  }

  @Test func stopTrackingStopsDetection() throws {
    let container = try TestModelContainer.create()
    let profileId = UUID()
    let syncEngine = ProfileSyncEngine(profileId: profileId, modelContainer: container)
    let tracker = ChangeTracker(syncEngine: syncEngine, modelContainer: container)
    tracker.startTracking()
    tracker.stopTracking()

    let context = ModelContext(container)
    let account = AccountRecord(
      id: UUID(), name: "AfterStop", type: "bank", position: 0,
      isHidden: false, currencyCode: "AUD"
    )
    context.insert(account)
    try context.save()

    #expect(!syncEngine.hasPendingChanges)
  }
}
