import Foundation
import Testing

@testable import Moolah

@Suite("TransactionRepository preserves ImportOrigin")
struct ImportOriginTransactionPersistenceTests {

  @Test("create + fetch preserves every ImportOrigin field")
  func roundTrip() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    let sessionId = UUID()
    let origin = ImportOrigin(
      rawDescription: "COFFEE @ SHOP",
      bankReference: "REF-42",
      rawAmount: Decimal(string: "-12.34")!,
      rawBalance: Decimal(string: "500.00")!,
      importedAt: Date(timeIntervalSince1970: 1_700_000_000),
      importSessionId: sessionId,
      sourceFilename: "cba.csv",
      parserIdentifier: "generic-bank")
    _ = try await backend.accounts.create(
      Account(
        id: accountId, name: "Cash", type: .bank,
        instrument: .AUD, positions: [], position: 0, isHidden: false),
      openingBalance: nil)
    let tx = Transaction(
      date: Date(timeIntervalSince1970: 1_700_000_000),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD,
          quantity: Decimal(string: "-12.34")!, type: .expense,
          categoryId: nil, earmarkId: nil)
      ],
      importOrigin: origin)
    _ = try await backend.transactions.create(tx)

    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId),
      page: 0, pageSize: 10)
    #expect(page.transactions.first?.importOrigin == origin)
  }

  @Test("create + fetch of a transaction without importOrigin returns nil")
  func nilOriginRoundTrip() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    _ = try await backend.accounts.create(
      Account(
        id: accountId, name: "Cash", type: .bank,
        instrument: .AUD, positions: [], position: 0, isHidden: false),
      openingBalance: nil)
    let tx = Transaction(
      date: Date(timeIntervalSince1970: 1_700_000_000),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD,
          quantity: Decimal(string: "-12.34")!, type: .expense,
          categoryId: nil, earmarkId: nil)
      ])
    _ = try await backend.transactions.create(tx)

    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId),
      page: 0, pageSize: 10)
    #expect(page.transactions.first?.importOrigin == nil)
  }

  @Test("update can set or clear importOrigin after create")
  func updateSetAndClear() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    _ = try await backend.accounts.create(
      Account(
        id: accountId, name: "Cash", type: .bank,
        instrument: .AUD, positions: [], position: 0, isHidden: false),
      openingBalance: nil)
    var tx = Transaction(
      date: Date(timeIntervalSince1970: 1_700_000_000),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD,
          quantity: Decimal(string: "-12.34")!, type: .expense,
          categoryId: nil, earmarkId: nil)
      ])
    _ = try await backend.transactions.create(tx)

    let sessionId = UUID()
    let origin = ImportOrigin(
      rawDescription: "Updated",
      bankReference: nil,
      rawAmount: Decimal(string: "-12.34")!,
      rawBalance: nil,
      importedAt: Date(timeIntervalSince1970: 1_700_000_000),
      importSessionId: sessionId,
      sourceFilename: nil,
      parserIdentifier: "generic-bank")
    tx.importOrigin = origin
    _ = try await backend.transactions.update(tx)

    var page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId),
      page: 0, pageSize: 10)
    #expect(page.transactions.first?.importOrigin == origin)

    tx.importOrigin = nil
    _ = try await backend.transactions.update(tx)
    page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId),
      page: 0, pageSize: 10)
    #expect(page.transactions.first?.importOrigin == nil)
  }
}
