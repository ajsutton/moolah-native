import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("InstrumentRegistryRepository — notifyExternalChange")
@MainActor
struct CloudKitInstrumentRegistryNotifyTests {
  @MainActor
  private func makeRepo() throws -> GRDBInstrumentRegistryRepository {
    let database = try ProfileDatabase.openInMemory()
    return GRDBInstrumentRegistryRepository(database: database)
  }

  @Test("notifyExternalChange yields to an active observeChanges subscriber")
  func notifyYieldsToActiveSubscriber() async throws {
    let repo = try makeRepo()
    let stream = repo.observeChanges()
    Task {
      // Give the consumer below time to reach `iterator.next()` so the
      // continuation is registered before the notification fires.
      try? await Task.sleep(for: .milliseconds(50))
      repo.notifyExternalChange()
    }
    var iterator = stream.makeAsyncIterator()
    let first: Void? = await iterator.next()
    try #require(first != nil)
  }

  @Test("notifyExternalChange fans out to multiple subscribers")
  func notifyYieldsToAllSubscribers() async throws {
    let repo = try makeRepo()
    let streamA = repo.observeChanges()
    let streamB = repo.observeChanges()
    var iteratorA = streamA.makeAsyncIterator()
    var iteratorB = streamB.makeAsyncIterator()

    Task {
      try? await Task.sleep(for: .milliseconds(50))
      repo.notifyExternalChange()
    }

    let firstA: Void? = await iteratorA.next()
    let firstB: Void? = await iteratorB.next()
    try #require(firstA != nil)
    try #require(firstB != nil)
  }
}
