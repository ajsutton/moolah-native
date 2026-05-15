// MoolahTests/Backends/GRDB/GRDBInstrumentRegistryRollbackTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Rollback contract test for the multi-statement write on
/// `GRDBInstrumentRegistryRepository.applyRemoteChangesSync`. Mirrors
/// `ProfileIndexRollbackTests` / `CSVImportRollbackTests` — per
/// `guides/DATABASE_CODE_GUIDE.md` §5 every multi-statement write must
/// roll back atomically when any statement throws, so prior on-disk
/// state survives byte-equal and no partial write lands.
///
/// `applyRemoteChangesSync` upserts every saved row and then deletes
/// every id inside a single `database.write` closure. A `BEFORE INSERT`
/// trigger that aborts on a sentinel `id` forces the second saved row's
/// INSERT to throw *inside* that transaction, so the first row's upsert
/// (which already mutated a pre-seeded row via the UPDATE side of the
/// conflict resolution) must roll back with it.
@Suite("Shared instrument-registry GRDB rollback contracts")
struct GRDBInstrumentRegistryRollbackTests {

  @Test
  func applyRemoteChangesSyncRollsBackOnFailure() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: database)

    // Seed an initial stored row whose ticker we'll attempt (and fail)
    // to mutate via the failing batch.
    let priorId = "1:0xabc"
    let prior = InstrumentRow(
      domain: Instrument.crypto(
        chainId: 1, contractAddress: "0xabc", symbol: "PRE", name: "Prior",
        decimals: 18))
    try await database.write { database in
      try prior.insert(database)
    }

    // Trigger that aborts any INSERT whose id matches the sentinel. The
    // first batch row upserts successfully (its id already exists, so
    // SQLite resolves the conflict via UPDATE); the second row's INSERT
    // trips the trigger inside `applyRemoteChangesSync`'s single
    // transaction, so every statement — including the upsert that
    // already touched `priorId` — must roll back.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_instrument_upsert
          BEFORE INSERT ON instrument
          WHEN NEW.id = '___FAIL___'
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    // Saved batch: a row that mutates the prior row's name (UPDATE side
    // of upsert) followed by a brand-new row that trips the trigger on
    // INSERT.
    var mutating = InstrumentRow(
      domain: Instrument.crypto(
        chainId: 1, contractAddress: "0xabc", symbol: "MUT",
        name: "MUTATED NAME THAT MUST NOT LAND", decimals: 18))
    mutating.recordName = prior.recordName
    var failing = InstrumentRow(
      domain: Instrument.crypto(
        chainId: 9, contractAddress: nil, symbol: "FAIL", name: "Fail",
        decimals: 18))
    failing.id = "___FAIL___"
    failing.recordName = "___FAIL___"

    do {
      try registry.applyRemoteChangesSync(saved: [mutating, failing], deleted: [])
      Issue.record("applyRemoteChangesSync should have thrown but did not")
    } catch {
      // Expected — trigger raises ABORT mid-transaction.
    }

    // The prior row's name survives byte-equal: the mutating upsert
    // never committed.
    let surviving = try #require(try registry.fetchRowSync(id: priorId))
    #expect(surviving.name == "Prior")
    // And the failing row was NOT persisted — no partial write.
    #expect(try registry.fetchRowSync(id: "___FAIL___") == nil)
    #expect(try registry.allRowIdsSync() == [priorId])
  }
}
