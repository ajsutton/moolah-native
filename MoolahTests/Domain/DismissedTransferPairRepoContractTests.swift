import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("DismissedTransferPairRepository Contract")
struct DismissedTransferPairRepoContractTests {
  @Test("creates and fetches a dismissed pair")
  func testCreateFetch() async throws {
    let repository = try makeRepository()
    let txA = UUID()
    let txB = UUID()
    let pair = DismissedTransferPair(
      transactionIds: [txA, txB], dismissedAt: Date(timeIntervalSince1970: 1000))

    let created = try await repository.create(pair)

    #expect(created.id == pair.id)
    #expect(created.transactionIds == [txA, txB])

    let all = try await repository.fetchAll()
    #expect(all.count == 1)
    #expect(all[0].transactionIds == [txA, txB])
  }

  @Test("re-creating the same unordered pair is idempotent")
  func testIdempotentUpsert() async throws {
    let repository = try makeRepository()
    let txA = UUID()
    let txB = UUID()
    // Same unordered pair, reversed argument order, later timestamp.
    let first = DismissedTransferPair(
      transactionIds: [txA, txB], dismissedAt: Date(timeIntervalSince1970: 1000))
    let second = DismissedTransferPair(
      transactionIds: [txB, txA], dismissedAt: Date(timeIntervalSince1970: 5000))
    #expect(first.id == second.id, "Deterministic id must be order-independent")

    _ = try await repository.create(first)
    _ = try await repository.create(second)

    let all = try await repository.fetchAll()
    #expect(all.count == 1, "Re-creating the same pair must upsert, not duplicate")
    #expect(all[0].dismissedAt == Date(timeIntervalSince1970: 5000))
  }

  @Test("pairs(touching:) returns every pair referencing the transaction")
  func testPairsTouching() async throws {
    let repository = try makeRepository()
    let shared = UUID()
    let other1 = UUID()
    let other2 = UUID()
    let unrelatedA = UUID()
    let unrelatedB = UUID()
    let first = DismissedTransferPair(
      transactionIds: [shared, other1], dismissedAt: Date(timeIntervalSince1970: 1))
    let second = DismissedTransferPair(
      transactionIds: [other2, shared], dismissedAt: Date(timeIntervalSince1970: 2))
    let unrelated = DismissedTransferPair(
      transactionIds: [unrelatedA, unrelatedB], dismissedAt: Date(timeIntervalSince1970: 3))
    _ = try await repository.create(first)
    _ = try await repository.create(second)
    _ = try await repository.create(unrelated)

    let touching = try await repository.pairs(touching: shared)

    #expect(touching.count == 2)
    #expect(Set(touching.map(\.id)) == [first.id, second.id])
    #expect(!touching.contains { $0.id == unrelated.id })
  }

  @Test("delete(id:) removes the pair")
  func testDelete() async throws {
    let repository = try makeRepository()
    let pair = DismissedTransferPair(
      transactionIds: [UUID(), UUID()], dismissedAt: Date(timeIntervalSince1970: 1))
    _ = try await repository.create(pair)

    try await repository.delete(id: pair.id)

    let all = try await repository.fetchAll()
    #expect(all.isEmpty)
  }

  @Test("observeAll emits the new pair after a create")
  func testObserveAllEmits() async throws {
    let repository = try makeRepository()
    var iterator = repository.observeAll().makeAsyncIterator()
    _ = await iterator.next()  // initial empty

    let pair = DismissedTransferPair(
      transactionIds: [UUID(), UUID()], dismissedAt: Date(timeIntervalSince1970: 1))
    _ = try await repository.create(pair)

    let afterCreate = await iterator.next()
    #expect(afterCreate?.count == 1)
    #expect(afterCreate?.first?.id == pair.id)
  }
}

private func makeRepository() throws -> any DismissedTransferPairRepository {
  let pair = try TestBackend.create()
  return pair.backend.dismissedTransferPairs
}
