// MoolahTests/Backends/GRDB/ProfileIndexRollbackTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Rollback contract tests for the multi-statement writes on
/// `GRDBProfileIndexRepository`. Mirrors `CSVImportRollbackTests` —
/// every multi-statement write must roll back atomically when any
/// statement throws, so prior on-disk state survives byte-equal.
///
/// The repo's `applyRemoteChangesSync` and `upsert` both touch more
/// than one row in their `database.write` closures (a saved-row
/// upsert paired with deletes; an existing-row lookup paired with the
/// upsert). Each test installs a `BEFORE INSERT` trigger that aborts
/// when a sentinel `label` value lands, drives the production code
/// path through the failure, and asserts the prior row is unchanged.
@Suite("Profile-index GRDB rollback contracts")
struct ProfileIndexRollbackTests {

  // MARK: - applyRemoteChangesSync

  @Test
  func applyRemoteChangesRollsBackOnFailure() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let repo = GRDBProfileIndexRepository(database: database)
    let priorId = UUID()
    let prior = makeRow(id: priorId, label: "prior-label")
    try await database.write { database in
      try prior.insert(database)
    }

    // Trigger that aborts any insert whose `label` matches the
    // sentinel. The first row in the batch upserts successfully (it
    // already exists, so SQLite resolves the conflict via UPDATE);
    // the second row's INSERT trips the trigger inside
    // `applyRemoteChangesSync`'s single transaction so all statements
    // (including the upsert that already touched the prior row) must
    // roll back.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_profile_upsert
          BEFORE INSERT ON profile
          WHEN NEW.label = '___FAIL___'
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    let mutating = makeRow(id: priorId, label: "mutated-prior")
    let failing = makeRow(id: UUID(), label: "___FAIL___")
    do {
      try repo.applyRemoteChangesSync(saved: [mutating, failing], deleted: [])
      Issue.record("applyRemoteChangesSync should have thrown but did not")
    } catch {
      // Expected — trigger raises ABORT.
    }

    // The prior row's label survives byte-equal — the mutated value
    // from the failed batch did NOT land on disk.
    let surviving = try #require(try repo.fetchRowSync(id: priorId))
    #expect(surviving.label == "prior-label")
    // And no new rows were created either.
    #expect(try repo.allRowIdsSync() == [priorId])
  }

  // MARK: - upsert

  @Test
  func upsertRollsBackOnFailure() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let repo = GRDBProfileIndexRepository(database: database)
    let priorId = UUID()
    let prior = makeRow(id: priorId, label: "prior-label")
    try await database.write { database in
      try prior.insert(database)
    }

    // Trigger that aborts an INSERT whose `label` matches the
    // sentinel. `upsert` first reads the existing row, then issues an
    // upsert; SQLite's upsert resolves a PK conflict via UPDATE, but
    // the trigger fires on the INSERT side of the upsert path. We
    // assert that even when the write fails, prior state is intact.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_profile_domain_upsert
          BEFORE INSERT ON profile
          WHEN NEW.label = '___FAIL___'
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    let domain = Profile(
      id: priorId,
      label: "___FAIL___",
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    do {
      try await repo.upsert(domain)
      Issue.record("upsert should have thrown but did not")
    } catch {
      // Expected — trigger raises ABORT.
    }

    let surviving = try #require(try repo.fetchRowSync(id: priorId))
    #expect(surviving.label == "prior-label")
    #expect(try repo.allRowIdsSync() == [priorId])
  }

  // MARK: - Helpers

  private func makeRow(id: UUID, label: String) -> ProfileRow {
    ProfileRow(
      id: id,
      recordName: ProfileRow.recordName(for: id),
      label: label,
      currencyCode: "AUD",
      financialYearStartMonth: 7,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      encodedSystemFields: nil)
  }
}
