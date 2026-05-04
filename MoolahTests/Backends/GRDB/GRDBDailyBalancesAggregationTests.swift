import Foundation
import Testing

@testable import Moolah

/// Aggregation-layer integration tests pinning that
/// `fetchDailyBalancesAggregation` populates the trades-mode fields
/// from `readDailyBalancesAggregation`. The fold-contract tests in
/// `GRDBDailyBalancesTradesModeTests` exercise the new fold by
/// constructing `DailyBalancesAggregation` directly; these tests
/// pin the SQL-to-struct wiring so a regression in the aggregation
/// builder doesn't ship past every fold-contract assertion.
@Suite("GRDBAnalysisRepository fetchDailyBalancesAggregation — trades-mode fields")
struct GRDBDailyBalancesAggregationTests {

  @Test("populates tradesModeInvestmentAccountIds for trades-mode accounts")
  func populatesTradesModeAccountIds() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let tradesAccount = Account(
      id: UUID(), name: "Trades Account", type: .investment,
      instrument: .defaultTestInstrument,
      valuationMode: .calculatedFromTrades)
    _ = try await backend.accounts.create(tradesAccount)
    let snapshotAccount = Account(
      id: UUID(), name: "Snapshot Account", type: .investment,
      instrument: .defaultTestInstrument,
      valuationMode: .recordedValue)
    _ = try await backend.accounts.create(snapshotAccount)

    let aggregation = try await backend.testFetchAggregation(
      after: nil, forecastUntil: nil)

    #expect(aggregation.tradesModeInvestmentAccountIds.contains(tradesAccount.id))
    #expect(!aggregation.tradesModeInvestmentAccountIds.contains(snapshotAccount.id))
    #expect(aggregation.investmentAccountIds.contains(snapshotAccount.id))
    #expect(!aggregation.investmentAccountIds.contains(tradesAccount.id))
  }

  @Test("priorTradesModeAccountRows / tradesModeAccountRows hold only trades-mode account rows")
  func filtersAccountRowsByMode() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let tradesAccount = Account(
      id: UUID(), name: "Trades Account", type: .investment,
      instrument: .defaultTestInstrument,
      valuationMode: .calculatedFromTrades)
    _ = try await backend.accounts.create(tradesAccount)
    let snapshotAccount = Account(
      id: UUID(), name: "Snapshot Account", type: .investment,
      instrument: .defaultTestInstrument,
      valuationMode: .recordedValue)
    _ = try await backend.accounts.create(snapshotAccount)
    let bankAccount = Account(
      id: UUID(), name: "Cash", type: .bank,
      instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(bankAccount)

    let cutoff = try AnalysisTestHelpers.date(year: 2025, month: 6, day: 1)
    let priorDate = try AnalysisTestHelpers.date(year: 2025, month: 5, day: 15)
    let postDate = try AnalysisTestHelpers.date(year: 2025, month: 6, day: 15)

    // One transaction on each side of the cutoff for each account.
    for (account, date) in [
      (tradesAccount, priorDate), (tradesAccount, postDate),
      (snapshotAccount, priorDate), (snapshotAccount, postDate),
      (bankAccount, priorDate), (bankAccount, postDate),
    ] {
      _ = try await backend.transactions.create(
        Transaction(
          date: date, payee: "Tick",
          legs: [
            TransactionLeg(
              accountId: account.id, instrument: .defaultTestInstrument,
              quantity: 10, type: .income)
          ]))
    }

    let aggregation = try await backend.testFetchAggregation(
      after: cutoff, forecastUntil: nil)

    let priorIds = Set(aggregation.priorTradesModeAccountRows.map(\.accountId))
    let postIds = Set(aggregation.tradesModeAccountRows.map(\.accountId))
    #expect(priorIds == [tradesAccount.id])
    #expect(postIds == [tradesAccount.id])
  }

  @Test("empty trades-mode profile produces empty arrays")
  func emptyTradesModeProfileEmptyArrays() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let snapshotAccount = Account(
      id: UUID(), name: "Snapshot Account", type: .investment,
      instrument: .defaultTestInstrument,
      valuationMode: .recordedValue)
    _ = try await backend.accounts.create(snapshotAccount)

    let aggregation = try await backend.testFetchAggregation(
      after: nil, forecastUntil: nil)

    #expect(aggregation.tradesModeInvestmentAccountIds.isEmpty)
    #expect(aggregation.priorTradesModeAccountRows.isEmpty)
    #expect(aggregation.tradesModeAccountRows.isEmpty)
  }
}
