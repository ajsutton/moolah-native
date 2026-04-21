import Foundation
import SwiftData
import XCTest

@testable import Moolah

/// Contract tests for `UITestSeedHydrator` — the code path that
/// `MoolahApp` uses when launched with `--ui-testing` to populate an
/// in-memory `ProfileContainerManager` from a named `UITestSeed`.
///
/// Hydration logic is deterministic: every call produces records with the
/// same UUIDs and values taken from `UITestFixtures`, regardless of when it
/// runs. These tests guard that contract so UI tests can reference fixtures
/// symbolically without worrying about non-determinism.
@MainActor
final class UITestSeedHydratorTests: XCTestCase {
  private var containerManager: ProfileContainerManager!

  override func setUp() async throws {
    try await super.setUp()
    containerManager = try ProfileContainerManager.forTesting()
  }

  override func tearDown() async throws {
    containerManager = nil
    try await super.tearDown()
  }

  // MARK: - Profile index

  func testHydrateTradeBaselineSeedsTheProfile() throws {
    _ = try UITestSeedHydrator.hydrate(.tradeBaseline, into: containerManager)

    let context = ModelContext(containerManager.indexContainer)
    let profiles = try context.fetch(FetchDescriptor<ProfileRecord>())
    XCTAssertEqual(profiles.count, 1, "expected exactly one seeded profile")
    let profile = try XCTUnwrap(profiles.first)
    XCTAssertEqual(profile.id, UITestFixtures.TradeBaseline.profileId)
    XCTAssertEqual(profile.label, UITestFixtures.TradeBaseline.profileLabel)
    XCTAssertEqual(profile.currencyCode, UITestFixtures.TradeBaseline.profileCurrencyCode)
  }

  func testHydrateReturnsSeededProfile() throws {
    let profile = try UITestSeedHydrator.hydrate(.tradeBaseline, into: containerManager)

    XCTAssertEqual(profile.id, UITestFixtures.TradeBaseline.profileId)
    XCTAssertEqual(profile.backendType, .cloudKit)
    XCTAssertEqual(profile.currencyCode, UITestFixtures.TradeBaseline.profileCurrencyCode)
  }

  // MARK: - Per-profile data

  func testHydrateTradeBaselineSeedsTheAccounts() throws {
    let profile = try UITestSeedHydrator.hydrate(.tradeBaseline, into: containerManager)
    let container = try containerManager.container(for: profile.id)

    let context = ModelContext(container)
    let accounts = try context.fetch(FetchDescriptor<AccountRecord>())
    XCTAssertEqual(accounts.count, 2, "expected checking + brokerage accounts")
    let ids = Set(accounts.map(\.id))
    XCTAssertEqual(
      ids,
      [
        UITestFixtures.TradeBaseline.checkingAccountId,
        UITestFixtures.TradeBaseline.brokerageAccountId,
      ]
    )
  }

  func testHydrateTradeBaselineSeedsTheTradeTransaction() throws {
    let profile = try UITestSeedHydrator.hydrate(.tradeBaseline, into: containerManager)
    let container = try containerManager.container(for: profile.id)

    let context = ModelContext(container)
    let tradeId = UITestFixtures.TradeBaseline.bhpPurchaseId
    let trade = try XCTUnwrap(
      try context.fetch(
        FetchDescriptor<TransactionRecord>(
          predicate: #Predicate { $0.id == tradeId }
        )
      ).first,
      "trade transaction must exist"
    )
    XCTAssertEqual(trade.payee, UITestFixtures.TradeBaseline.bhpPurchasePayee)

    let legs = try context.fetch(
      FetchDescriptor<TransactionLegRecord>(
        predicate: #Predicate { $0.transactionId == tradeId }
      )
    )
    XCTAssertEqual(legs.count, 2, "expected two legs on the trade transaction")
    let accountIds = Set(legs.compactMap(\.accountId))
    XCTAssertEqual(
      accountIds,
      [
        UITestFixtures.TradeBaseline.checkingAccountId,
        UITestFixtures.TradeBaseline.brokerageAccountId,
      ]
    )
  }

  func testHydrateTradeBaselineSeedsTheHistoricalPayees() throws {
    let profile = try UITestSeedHydrator.hydrate(.tradeBaseline, into: containerManager)
    let container = try containerManager.container(for: profile.id)

    let context = ModelContext(container)
    let historicalIds = Set(UITestFixtures.TradeBaseline.historicalPayees.map(\.id))
    let allTransactions = try context.fetch(FetchDescriptor<TransactionRecord>())
    let historicals = allTransactions.filter { historicalIds.contains($0.id) }
    XCTAssertEqual(
      historicals.count,
      UITestFixtures.TradeBaseline.historicalPayees.count,
      "expected every historical payee to be seeded"
    )

    let payees = historicals.compactMap(\.payee).sorted()
    XCTAssertEqual(
      payees,
      ["Coles", "Woolworths", "Woolworths", "Woolworths Metro"],
      "historical payees must match fixture list exactly"
    )

    // Each historical has exactly one expense leg on Checking.
    for historical in historicals {
      let txnId = historical.id
      let legs = try context.fetch(
        FetchDescriptor<TransactionLegRecord>(
          predicate: #Predicate { $0.transactionId == txnId }
        )
      )
      XCTAssertEqual(legs.count, 1, "historical \(historical.payee ?? "?") should have 1 leg")
      XCTAssertEqual(legs.first?.accountId, UITestFixtures.TradeBaseline.checkingAccountId)
      XCTAssertEqual(legs.first?.type, TransactionType.expense.rawValue)
    }
  }

  // MARK: - Determinism

  func testHydrateIsIdempotentWhenRunTwice() throws {
    _ = try UITestSeedHydrator.hydrate(.tradeBaseline, into: containerManager)
    let first = try containerManager.container(for: UITestFixtures.TradeBaseline.profileId)
    let firstTxnCount = try ModelContext(first).fetch(FetchDescriptor<TransactionRecord>()).count

    // Running hydration again on the same manager should not double-insert.
    _ = try UITestSeedHydrator.hydrate(.tradeBaseline, into: containerManager)
    let second = try containerManager.container(for: UITestFixtures.TradeBaseline.profileId)
    let secondTxnCount = try ModelContext(second).fetch(FetchDescriptor<TransactionRecord>()).count

    let expected = 1 + UITestFixtures.TradeBaseline.historicalPayees.count
    XCTAssertEqual(firstTxnCount, expected)
    XCTAssertEqual(secondTxnCount, expected, "hydration must be idempotent for robust relaunches")
  }
}
