import Foundation
import Testing

@testable import Moolah

@Suite("RecentlyAddedViewModel")
@MainActor
struct RecentlyAddedViewModelTests {

  private func date(offsetHours: Int, from now: Date = Date()) -> Date {
    now.addingTimeInterval(Double(offsetHours) * 3_600)
  }

  private func stamped(
    origin: ImportOrigin?,
    legs: [TransactionLeg] = [],
    date: Date = Date()
  ) -> Transaction {
    Transaction(date: date, legs: legs, importOrigin: origin)
  }

  private func origin(
    sessionId: UUID,
    importedAt: Date,
    filename: String? = nil
  ) -> ImportOrigin {
    ImportOrigin(
      rawDescription: "x",
      bankReference: nil,
      rawAmount: 0,
      rawBalance: nil,
      importedAt: importedAt,
      importSessionId: sessionId,
      sourceFilename: filename,
      parserIdentifier: "generic-bank")
  }

  @Test("filter keeps only transactions whose importedAt falls within the window")
  func filterWindow() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let session = UUID()
    let inside = stamped(
      origin: origin(sessionId: session, importedAt: now.addingTimeInterval(-3_600)))
    let outside = stamped(
      origin: origin(sessionId: session, importedAt: now.addingTimeInterval(-86_400 * 2)))
    let noOrigin = stamped(origin: nil)
    let kept = RecentlyAddedViewModel.filter(
      [inside, outside, noOrigin], window: .last24Hours, now: now)
    #expect(kept.count == 1)
    #expect(kept[0] == inside)
  }

  @Test("group bundles transactions by importSessionId and sorts newest-first")
  func groupBySession() {
    let sessionA = UUID()
    let sessionB = UUID()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let olderA = stamped(
      origin: origin(
        sessionId: sessionA, importedAt: now.addingTimeInterval(-3_600),
        filename: "a.csv"))
    let newerA = stamped(
      origin: origin(sessionId: sessionA, importedAt: now, filename: "a.csv"))
    let newerB = stamped(
      origin: origin(
        sessionId: sessionB, importedAt: now.addingTimeInterval(-60),
        filename: "b.csv"))
    let groups = RecentlyAddedViewModel.group([olderA, newerA, newerB])
    #expect(groups.count == 2)
    // Session A is newest because its most-recent tx is at `now`.
    #expect(groups[0].id == sessionA)
    #expect(groups[0].filenames == ["a.csv"])
    #expect(groups[0].transactions.count == 2)
    #expect(groups[1].id == sessionB)
  }

  @Test("badge count + session load against TestBackend")
  func loadViaBackend() async throws {
    let (backend, container) = try TestBackend.create()
    let accountId = UUID()
    _ = try await backend.accounts.create(
      Account(
        id: accountId, name: "Cash", type: .bank, instrument: .AUD,
        positions: [], position: 0, isHidden: false),
      openingBalance: nil)

    let now = Date()
    let sessionId = UUID()
    let categorisedOrigin = origin(
      sessionId: sessionId, importedAt: now.addingTimeInterval(-60), filename: "cba.csv")
    let uncategorisedOrigin = origin(
      sessionId: sessionId, importedAt: now.addingTimeInterval(-30), filename: "cba.csv")
    let outsideOrigin = origin(
      sessionId: sessionId, importedAt: now.addingTimeInterval(-86_400 * 2),
      filename: "old.csv")

    let categorisedTxs = [
      Transaction(
        date: now,
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: .AUD, quantity: -5, type: .expense,
            categoryId: UUID(), earmarkId: nil)
        ],
        importOrigin: categorisedOrigin),
      Transaction(
        date: now,
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: .AUD, quantity: -10, type: .expense,
            categoryId: UUID(), earmarkId: nil)
        ],
        importOrigin: categorisedOrigin),
    ]
    let uncategorisedTxs = [
      Transaction(
        date: now,
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: .AUD, quantity: -3, type: .expense,
            categoryId: nil, earmarkId: nil)
        ],
        importOrigin: uncategorisedOrigin),
      Transaction(
        date: now,
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: .AUD, quantity: -4, type: .expense,
            categoryId: nil, earmarkId: nil)
        ],
        importOrigin: uncategorisedOrigin),
      Transaction(
        date: now,
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: .AUD, quantity: -2, type: .expense,
            categoryId: nil, earmarkId: nil)
        ],
        importOrigin: uncategorisedOrigin),
    ]
    let outsideTx = Transaction(
      date: now.addingTimeInterval(-86_400 * 2),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD, quantity: -1, type: .expense,
          categoryId: nil, earmarkId: nil)
      ],
      importOrigin: outsideOrigin)
    TestBackend.seed(
      transactions: categorisedTxs + uncategorisedTxs + [outsideTx], in: container)

    let viewModel = RecentlyAddedViewModel(backend: backend)
    await viewModel.load(window: .last24Hours, now: now)
    #expect(viewModel.badgeCount == 3)
    #expect(viewModel.sessions.count == 1)
    #expect(viewModel.sessions[0].transactions.count == 5)
  }
}
