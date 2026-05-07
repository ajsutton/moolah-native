// MoolahTests/Shared/CryptoImport/CrossDeviceLegDeduperTestSupport.swift
import Foundation
import GRDB

@testable import Moolah

/// Shared fixtures for the `CrossDeviceLegDeduper*Tests` suites. Lives
/// outside any one suite so the convergence, scoping, and determinism
/// tests can split into focused files without duplicating the seeding /
/// permutation glue.
///
/// Case-less enum used as a namespace per `guides/CODE_GUIDE.md` §5.
enum CrossDeviceLegDeduperTestSupport {
  /// Two stable transaction ids — `txnA < txnB < txnC` by lex order of
  /// the lowercase UUID string. The deduper picks the lowest UUID as
  /// canonical, so pinning these literals lets the suite assert on
  /// exact survivors.
  static let txnA = makeUUID("11111111-1111-1111-1111-111111111111")
  static let txnB = makeUUID("22222222-2222-2222-2222-222222222222")
  static let txnC = makeUUID("33333333-3333-3333-3333-333333333333")
  static let accountA = makeUUID("AAAAAAAA-0000-0000-0000-000000000001")
  static let accountB = makeUUID("BBBBBBBB-0000-0000-0000-000000000002")
  static let hash = "0xshared-on-chain-hash"
  static let date = Date(timeIntervalSince1970: 1_700_000_000)

  /// Backend + database pair plus the seeding helpers each test uses.
  /// Holding onto the database queue is required: `TestBackend.seed`
  /// writes through it, and the in-memory queue would be deallocated
  /// between operations otherwise.
  struct Setup {
    let backend: CloudKitBackend
    let database: DatabaseQueue

    func seedAccount(_ id: UUID) {
      let account = Account(
        id: id,
        name: "Account \(id.uuidString.prefix(4))",
        type: .crypto,
        instrument: ChainConfig.ethereum.nativeInstrument,
        walletAddress: "0x" + String(repeating: "1", count: 40),
        chainId: ChainConfig.ethereum.chainId)
      _ = TestBackend.seed(accounts: [account], in: database)
    }

    func create(_ transaction: Transaction) async throws {
      _ = try await backend.transactions.create(transaction)
    }
  }

  /// Builds a `TestBackend` and **drops the partial unique index**
  /// `leg_dedup_by_account_external` so the test can seed two
  /// `TransactionLeg` rows sharing `(accountId, externalId)`. In
  /// production the index is the device-local guard against duplicate
  /// imports; the cross-device race the deduper exists to clean up
  /// would have been blocked by it on the apply path. The deduper is
  /// designed to be defensive even when duplicates do land — the
  /// design (`plans/2026-05-05-crypto-wallet-import-design.md`
  /// §"Multi-device race window") explicitly calls out the upsert
  /// path not re-running the dedup. Dropping the index in tests lets
  /// the suite exercise the deduper's algorithm against the same
  /// shape of state the post-CKSyncEngine sweep would face.
  ///
  /// The deduper itself only performs `SELECT` and `delete(id:)`
  /// calls, never inserts that would otherwise re-tripped the index,
  /// so leaving the index dropped for the rest of the test is safe.
  static func makeSetup() throws -> Setup {
    let (backend, database) = try TestBackend.create()
    try database.write { database in
      try database.execute(sql: "DROP INDEX IF EXISTS leg_dedup_by_account_external")
    }
    return Setup(backend: backend, database: database)
  }

  static func makeLeg(
    accountId: UUID,
    quantity: Decimal,
    externalId: String,
    type: TransactionType
  ) -> TransactionLeg {
    TransactionLeg(
      accountId: accountId,
      instrument: ChainConfig.ethereum.nativeInstrument,
      quantity: quantity,
      externalId: externalId,
      type: type)
  }

  /// Returns a transaction with one leg shaped for the cross-device
  /// duplicate scenarios. Most tests need exactly this shape — pulling
  /// it into a helper keeps the suites focused on what they're
  /// actually asserting.
  static func makeSingleLegTransaction(
    id: UUID,
    accountId: UUID,
    externalId: String,
    quantity: Decimal = -1
  ) -> Transaction {
    // Mirror `TransferEventBuilder`'s per-account types: positive
    // quantity → `.income`, negative → `.expense`.
    let legType: TransactionType = quantity >= 0 ? .income : .expense
    return Transaction(
      id: id,
      date: Self.date,
      legs: [
        makeLeg(
          accountId: accountId,
          quantity: quantity,
          externalId: externalId,
          type: legType)
      ])
  }

  /// Generates every permutation of an input array — used to exercise
  /// the deterministic-across-input-order invariant exhaustively for
  /// small inputs without relying on a randomness seed.
  static func permutations<Element>(of input: [Element]) -> [[Element]] {
    guard input.count > 1 else { return [input] }
    var result: [[Element]] = []
    for index in input.indices {
      var rest = input
      let pivot = rest.remove(at: index)
      for tail in permutations(of: rest) {
        result.append([pivot] + tail)
      }
    }
    return result
  }
}
