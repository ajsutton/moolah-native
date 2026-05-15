// MoolahTests/Backends/GRDB/GRDBCreatePathRegistersInstrumentTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Pins the cross-transaction atomicity boundary introduced by the write
/// cutover: instrument registration commits in its OWN transaction BEFORE
/// the per-profile write that inserts the transaction/leg rows. If the
/// per-profile write later fails and rolls back, the instrument row
/// persists — safe because `registerResolvable` is idempotent and a
/// retry will succeed. No existing rollback test covers this asymmetric
/// boundary because the existing fiat-only rollback tests go through
/// `registerResolvable` as a no-op.
///
/// The in-transaction throw is forced by a `BEFORE INSERT ON "transaction"`
/// SQLite trigger so the abort fires inside the per-profile write block,
/// after `registerResolvable` has already committed on its separate DB
/// queue write.
@Suite("Cross-transaction atomicity: registration persists when per-profile write rolls back")
struct GRDBInstrumentRegistrationRollbackTests {

  @Test(
    """
    instrument row persists after per-profile write rolls back (register-then-write contract)
    """
  )
  func instrumentRowPersistsAfterPerProfileWriteRollback() async throws {
    let perProfile = try ProfileDatabase.openInMemory()

    // `PerProfileInstrumentRegistrar` writes the instrument row in its own
    // separate `database.write` BEFORE the per-profile transaction/leg
    // write. This is the boundary under test: the registrar's write is
    // NOT part of the per-profile write transaction.
    let repo = GRDBTransactionRepository(
      database: perProfile,
      defaultInstrument: Instrument.fiat(code: "USD"),
      conversionService: FixedConversionService(),
      instrumentResolver: PerProfileInstrumentMapResolver(database: perProfile),
      instrumentRegistrar: PerProfileInstrumentRegistrar(database: perProfile))

    // Install a trigger that aborts every INSERT into the `transaction`
    // table. The per-profile write inserts the transaction header first,
    // so the trigger fires there and rolls back the entire per-profile
    // write (header + legs). The registration write has already
    // committed by the time this trigger fires.
    try await perProfile.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_txn_insert
          BEFORE INSERT ON "transaction"
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum",
      decimals: 18)
    let leg = TransactionLeg(
      accountId: UUID(), instrument: eth, quantity: 1, type: .income)
    let txn = Transaction(
      date: Date(timeIntervalSince1970: 1_700_000_000), payee: "Buy ETH",
      legs: [leg])

    await #expect(throws: (any Error).self) {
      try await repo.create(txn)
    }

    // The registrar committed its write before the per-profile write;
    // that registration is NOT rolled back with the failing write. This
    // is the intentional cross-transaction atomicity contract: register
    // then write; registration is not rolled back with a failed
    // per-profile write; safe because idempotent.
    let instrumentRows = try await perProfile.read { database in
      try InstrumentRow
        .filter(InstrumentRow.Columns.id == eth.id)
        .fetchAll(database)
    }
    #expect(
      instrumentRows.count == 1, "instrument row must persist after per-profile write rolls back")

    // The per-profile transaction write did roll back: no transaction
    // header and no legs on disk.
    let txnRows = try await perProfile.read { database in
      try TransactionRow.fetchAll(database)
    }
    let legRows = try await perProfile.read { database in
      try TransactionLegRow.fetchAll(database)
    }
    #expect(txnRows.isEmpty, "transaction row must not persist after per-profile write rolls back")
    #expect(legRows.isEmpty, "leg row must not persist after per-profile write rolls back")
  }
}

/// Pins the instrument write cutover: `create` (transaction and account) no
/// longer plants a per-profile placeholder `instrument` row. Instead it
/// awaits `InstrumentRegistering.registerResolvable` *before* the
/// per-profile write, so an immediately-following read resolves the
/// instrument.
///
/// Production-shaped wiring: a SHARED `GRDBInstrumentRegistryRepository`
/// over `ProfileIndexDatabase.openInMemory()` is injected as BOTH the
/// `instrumentResolver` and the `instrumentRegistrar`; the txn / leg /
/// account rows land in a separate `ProfileDatabase.openInMemory()`. The
/// proof is two-sided:
///   1. the instrument is resolvable from the shared registry after
///      `create` — `instrumentMap()` (the exact read every production
///      resolver path consults) returns the full crypto `Instrument`,
///      not the `Instrument.fiat(code:)` fallback. (A priced /
///      no-mapping registration is intentionally hidden from
///      `cryptoRegistration(byId:)` — that is the inbox projection — so
///      resolvability must be probed via the resolver the read paths
///      actually use.)
///   2. the per-profile `instrument` table has ZERO rows for that id
///      (the placeholder write is gone).
@Suite("create registers the instrument via the shared registry, not a per-profile placeholder")
struct GRDBCreatePathRegistersInstrumentTests {
  private func perProfileInstrumentRowCount(
    _ database: any DatabaseWriter, id: String
  ) async throws -> Int {
    try await database.read { database in
      try InstrumentRow
        .filter(InstrumentRow.Columns.id == id)
        .fetchCount(database)
    }
  }

  @Test("transaction create registers a new crypto leg in the shared registry")
  func transactionCreateRegistersInSharedRegistry() async throws {
    let perProfile = try ProfileDatabase.openInMemory()
    let sharedQueue = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: sharedQueue)

    let repo = GRDBTransactionRepository(
      database: perProfile,
      defaultInstrument: Instrument.fiat(code: "USD"),
      conversionService: FixedConversionService(),
      instrumentResolver: registry,
      instrumentRegistrar: registry)

    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum",
      decimals: 18)
    let account = Account(
      name: "Trust - Ethereum", type: .crypto, instrument: eth,
      valuationMode: .calculatedFromTrades, walletAddress: "0xabc",
      chainId: 1)
    let leg = TransactionLeg(
      accountId: account.id, instrument: eth, quantity: 3, type: .income)
    let txn = Transaction(
      date: Date(timeIntervalSince1970: 1_700_000_000), payee: "in",
      legs: [leg])

    _ = try await repo.create(txn)

    // (1) resolvable from the shared registry after create — the
    // resolver returns the full crypto instrument, not a fiat fallback.
    let resolved = try await registry.instrumentMap()[eth.id]
    #expect(resolved == eth, "create must register the crypto so the resolver resolves it")
    #expect(resolved?.kind == .cryptoToken)

    // (2) no per-profile placeholder row was written.
    let count = try await perProfileInstrumentRowCount(perProfile, id: eth.id)
    #expect(count == 0, "create must not write a per-profile instrument placeholder")
  }

  @Test("account create registers a new crypto denomination in the shared registry")
  func accountCreateRegistersInSharedRegistry() async throws {
    let perProfile = try ProfileDatabase.openInMemory()
    let sharedQueue = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: sharedQueue)

    let repo = GRDBAccountRepository(
      database: perProfile,
      instrumentResolver: registry,
      instrumentRegistrar: registry)

    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum",
      decimals: 18)
    let account = Account(
      name: "Trust - Ethereum", type: .crypto, instrument: eth,
      valuationMode: .calculatedFromTrades, walletAddress: "0xabc",
      chainId: 1)

    _ = try await repo.create(account)

    let resolved = try await registry.instrumentMap()[eth.id]
    #expect(
      resolved == eth,
      "account create must register the crypto so the resolver resolves it")
    #expect(resolved?.kind == .cryptoToken)

    let count = try await perProfileInstrumentRowCount(perProfile, id: eth.id)
    #expect(count == 0, "account create must not write a per-profile instrument placeholder")
  }

  @Test("per-profile registrar keeps create→read resolvable behind the seam")
  func perProfileRegistrarPreservesResolution() async throws {
    let perProfile = try ProfileDatabase.openInMemory()

    let repo = GRDBTransactionRepository(
      database: perProfile,
      defaultInstrument: Instrument.fiat(code: "USD"),
      conversionService: FixedConversionService(),
      instrumentResolver: PerProfileInstrumentMapResolver(database: perProfile),
      instrumentRegistrar: PerProfileInstrumentRegistrar(database: perProfile))

    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum",
      decimals: 18)
    let account = Account(
      name: "Trust - Ethereum", type: .crypto, instrument: eth,
      valuationMode: .calculatedFromTrades, walletAddress: "0xabc",
      chainId: 1)
    let leg = TransactionLeg(
      accountId: account.id, instrument: eth, quantity: 3, type: .income)
    let txn = Transaction(
      date: Date(timeIntervalSince1970: 1_700_000_000), payee: "in",
      legs: [leg])

    try await perProfile.write { database in
      try AccountRow(domain: account).insert(database)
    }
    _ = try await repo.create(txn)

    // The per-profile registrar wrote the row behind the seam, so the
    // per-profile resolver still resolves the full crypto instrument.
    let fetched = try await repo.fetchAll(
      filter: TransactionFilter(accountId: account.id))
    let resolvedLeg = try #require(fetched.first?.legs.first)
    #expect(resolvedLeg.instrument == eth)
    #expect(resolvedLeg.instrument.kind == .cryptoToken)
  }
}
