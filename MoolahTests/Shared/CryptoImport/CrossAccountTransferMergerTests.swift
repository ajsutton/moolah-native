// MoolahTests/Shared/CryptoImport/CrossAccountTransferMergerTests.swift
import Foundation
import Testing

@testable import Moolah

/// Behavioural tests for `CrossAccountTransferMerger`. The merger is
/// pure — no repository writes, no shared state — so every test
/// constructs `BuiltTransaction`s in-line and feeds them through
/// `merge(candidates:existingLegLookup:)` with a closure that supplies
/// any prior-cycle legs the test wants the merger to see.
@Suite("CrossAccountTransferMerger")
struct CrossAccountTransferMergerTests {
  // Two stable account ids — A < B by UUID-string lex order so the
  // determinism tests can assert on the lower-UUID-wins rule. Stamping
  // them as raw UUIDs (not generated per-call) keeps the suite
  // reproducible.
  private static let accountA = makeUUID("00000000-0000-0000-0000-0000000000A1")
  private static let accountB = makeUUID("00000000-0000-0000-0000-0000000000B2")
  private static let hash = "0xdeadbeef"

  private static let dateA = Date(timeIntervalSince1970: 1_700_000_000)
  private static let dateB = Date(timeIntervalSince1970: 1_700_000_500)

  // MARK: - Pair predicate

  @Test("Same hash + opposing legs collapses to a single multi-leg transaction")
  func mergesOpposingPairOnSameExternalId() async throws {
    let outbound = makeBuiltTransaction(
      accountId: Self.accountA,
      hash: Self.hash,
      instrument: TestInstruments.ethereum,
      quantity: -1,
      date: Self.dateA)
    let inbound = makeBuiltTransaction(
      accountId: Self.accountB,
      hash: Self.hash,
      instrument: TestInstruments.ethereum,
      quantity: 1,
      date: Self.dateB)

    let merged = try await LiveCrossAccountTransferMerger().merge(
      candidates: [outbound, inbound],
      existingLegLookup: { _ in [] })

    #expect(merged.count == 1)
    let result = try #require(merged.first)
    #expect(result.transaction.legs.count == 2)
    let signs = result.transaction.legs.map { $0.quantity > 0 ? "+" : "-" }
    #expect(Set(signs) == Set(["+", "-"]))
    let externalIds = Set(result.transaction.legs.compactMap(\.externalId))
    #expect(externalIds == [Self.hash])
  }

  @Test("Same hash + same-sign legs are NOT merged (multi-recipient airdrop, issue #750)")
  func skipsSameSignPair() async throws {
    let firstInbound = makeBuiltTransaction(
      accountId: Self.accountA, hash: Self.hash,
      instrument: TestInstruments.ethereum, quantity: 1)
    let secondInbound = makeBuiltTransaction(
      accountId: Self.accountB, hash: Self.hash,
      instrument: TestInstruments.ethereum, quantity: 1)

    let merged = try await LiveCrossAccountTransferMerger().merge(
      candidates: [firstInbound, secondInbound],
      existingLegLookup: { _ in [] })

    #expect(merged.count == 2)
  }

  @Test("Same hash + different instruments are NOT merged (cross-chain bridge)")
  func skipsDifferentInstrumentPair() async throws {
    let outbound = makeBuiltTransaction(
      accountId: Self.accountA, hash: Self.hash,
      instrument: TestInstruments.ethereum, quantity: -1)
    let inbound = makeBuiltTransaction(
      accountId: Self.accountB, hash: Self.hash,
      instrument: TestInstruments.polygon, quantity: 1)

    let merged = try await LiveCrossAccountTransferMerger().merge(
      candidates: [outbound, inbound],
      existingLegLookup: { _ in [] })

    #expect(merged.count == 2)
  }

  @Test("Same hash + same account is NOT merged (self-send)")
  func skipsSameAccountPair() async throws {
    let outbound = makeBuiltTransaction(
      accountId: Self.accountA, hash: Self.hash,
      instrument: TestInstruments.ethereum, quantity: -1)
    let inbound = makeBuiltTransaction(
      accountId: Self.accountA, hash: Self.hash,
      instrument: TestInstruments.ethereum, quantity: 1)

    let merged = try await LiveCrossAccountTransferMerger().merge(
      candidates: [outbound, inbound],
      existingLegLookup: { _ in [] })

    #expect(merged.count == 2)
  }

  // MARK: - Fee legs

  @Test("Fee legs from both sides are preserved on the merged transaction")
  func preservesFeeLegsOnMerge() async throws {
    let gasInstrument = TestInstruments.ethereum
    // Fee legs use the `:gas` `externalId` suffix per
    // `TransferReceiptCoalescer.gasLegExternalId(hash:)` so they're
    // distinguishable from the value-bearing leg by externalId alone —
    // both legs are `.expense`-typed when the value side is outbound.
    let outboundFee = TransactionLeg(
      accountId: Self.accountA,
      instrument: gasInstrument,
      quantity: try #require(Decimal(string: "-0.001")),
      externalId: "\(Self.hash):gas",
      type: .expense)
    let outbound = makeBuiltTransaction(
      accountId: Self.accountA, hash: Self.hash,
      instrument: gasInstrument, quantity: -1,
      extraLegs: [outboundFee])

    let inboundFee = TransactionLeg(
      accountId: Self.accountB,
      instrument: gasInstrument,
      quantity: try #require(Decimal(string: "-0.0005")),
      externalId: "\(Self.hash):gas",
      type: .expense)
    let inbound = makeBuiltTransaction(
      accountId: Self.accountB, hash: Self.hash,
      instrument: gasInstrument, quantity: 1,
      extraLegs: [inboundFee])

    let merged = try await LiveCrossAccountTransferMerger().merge(
      candidates: [outbound, inbound],
      existingLegLookup: { _ in [] })

    #expect(merged.count == 1)
    let result = try #require(merged.first)
    // Filter by the `:gas` `externalId` suffix; value-bearing
    // outbound legs are now `.expense` too, so type alone no longer
    // disambiguates fee from value.
    let feeLegs = result.transaction.legs.filter {
      $0.externalId?.hasSuffix(":gas") == true
    }
    #expect(feeLegs.count == 2)
  }

  // MARK: - Existing-leg lookup

  @Test("In-batch candidate pairs against a leg already persisted on a prior cycle")
  func mergesAgainstExistingPersistedLeg() async throws {
    // Prior-cycle outbound leg, persisted by an earlier sync. The
    // wallet importer would have written this as `.expense` per its
    // per-account type rule.
    let priorCycleLeg = TransactionLeg(
      accountId: Self.accountA,
      instrument: TestInstruments.ethereum,
      quantity: -1,
      externalId: Self.hash,
      type: .expense)

    let inbound = makeBuiltTransaction(
      accountId: Self.accountB, hash: Self.hash,
      instrument: TestInstruments.ethereum, quantity: 1)

    let merged = try await LiveCrossAccountTransferMerger().merge(
      candidates: [inbound],
      existingLegLookup: { externalId in
        externalId == Self.hash ? [priorCycleLeg] : []
      })

    #expect(merged.count == 1)
    let result = try #require(merged.first)
    #expect(result.transaction.legs.count == 2)
    // Both the in-batch candidate's leg and the persisted leg surface;
    // dedup at the apply layer drops the persisted one when the candidate
    // is rewritten — the merger's contract is just to expose the merged
    // shape so the transfer-detection engine sees one event, not two.
    let externalIds = result.transaction.legs.compactMap(\.externalId)
    #expect(externalIds.allSatisfy { $0 == Self.hash })
  }

  // MARK: - Determinism

  @Test("originAccountId on the merged value is the lower-UUID side")
  func mergedOriginIsLowerUuid() async throws {
    let outbound = makeBuiltTransaction(
      accountId: Self.accountB, hash: Self.hash,
      instrument: TestInstruments.ethereum, quantity: -1, date: Self.dateB)
    let inbound = makeBuiltTransaction(
      accountId: Self.accountA, hash: Self.hash,
      instrument: TestInstruments.ethereum, quantity: 1, date: Self.dateA)

    let merged = try await LiveCrossAccountTransferMerger().merge(
      candidates: [outbound, inbound],
      existingLegLookup: { _ in [] })

    let result = try #require(merged.first)
    #expect(result.originAccountId == Self.accountA)
  }

  @Test("Date on the merged transaction is the earlier of the two")
  func mergedDateIsEarlier() async throws {
    let outbound = makeBuiltTransaction(
      accountId: Self.accountA, hash: Self.hash,
      instrument: TestInstruments.ethereum, quantity: -1, date: Self.dateB)
    let inbound = makeBuiltTransaction(
      accountId: Self.accountB, hash: Self.hash,
      instrument: TestInstruments.ethereum, quantity: 1, date: Self.dateA)

    let merged = try await LiveCrossAccountTransferMerger().merge(
      candidates: [outbound, inbound],
      existingLegLookup: { _ in [] })

    let result = try #require(merged.first)
    #expect(result.transaction.date == Self.dateA)
  }

  // MARK: - Helpers

  private func makeBuiltTransaction(
    accountId: UUID,
    hash: String,
    instrument: Instrument,
    quantity: Decimal,
    date: Date = Date(timeIntervalSince1970: 1_700_000_000),
    extraLegs: [TransactionLeg] = []
  ) -> BuiltTransaction {
    // Wallet importer types: outbound (negative qty) → `.expense`,
    // inbound (positive qty) → `.income`. The merger then pairs
    // (.income, .expense) tuples on opposing-sign quantities.
    let legType: TransactionType = quantity >= 0 ? .income : .expense
    let transferLeg = TransactionLeg(
      accountId: accountId,
      instrument: instrument,
      quantity: quantity,
      externalId: hash,
      type: legType)
    let transaction = Transaction(
      date: date,
      legs: [transferLeg] + extraLegs,
      importOrigin: ImportOrigin(
        rawDescription: "wallet:\(accountId.uuidString)",
        rawAmount: 0,
        importedAt: date,
        importSessionId: UUID(),
        parserIdentifier: "alchemy-wallet-sync"))
    return BuiltTransaction(originAccountId: accountId, transaction: transaction)
  }
}

/// Native instruments for the chains the merger tests reuse across
/// cases. File-scoped helpers avoid extending `Instrument` with
/// fileprivate test-only members (which conflict with `swift-format`'s
/// hoisting of `fileprivate` out of `private extension`).
private enum TestInstruments {
  static let ethereum: Instrument = ChainConfig.ethereum.nativeInstrument
  static let polygon: Instrument = ChainConfig.polygon.nativeInstrument
}
