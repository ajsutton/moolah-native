// Backends/GRDB/Repositories/GRDBWalletSyncStateRepository.swift

import Foundation
import GRDB

/// GRDB-backed implementation of `WalletSyncStateRepository`. Stores
/// per-device sync checkpoints for crypto wallet accounts in the local
/// `wallet_sync_state` table. NOT synced via CKSyncEngine (intentional —
/// see `WalletSyncStateRepository` doc-comment).
///
/// Implemented as a `Sendable` struct (not a `final class` with
/// `@unchecked Sendable`) per CONCURRENCY_GUIDE §2: the only stored
/// property is `let database: any DatabaseWriter`, which GRDB
/// guarantees is `Sendable`. There is no mutable state, no
/// `@MainActor`-isolated closures, no observation fan-out — none of
/// the genuine reasons that force `@unchecked` in
/// `GRDBInstrumentRegistryRepository`.
struct GRDBWalletSyncStateRepository: WalletSyncStateRepository, Sendable {
  private let database: any DatabaseWriter

  init(database: any DatabaseWriter) {
    self.database = database
  }

  func loadAll() async throws -> [WalletSyncState] {
    try await database.read { database in
      try WalletSyncStateRow.fetchAll(database).map { try $0.toDomain() }
    }
  }

  func load(accountId: UUID) async throws -> WalletSyncState? {
    try await database.read { database in
      try WalletSyncStateRow
        .filter(WalletSyncStateRow.Columns.accountId == accountId)
        .fetchOne(database)?
        .toDomain()
    }
  }

  func save(_ state: WalletSyncState) async throws {
    // Single-statement GRDB upsert — atomically replaces any existing
    // row keyed on `account_id` (PRIMARY KEY); no multi-statement
    // rollback test required (DATABASE_CODE_GUIDE §5).
    try await database.write { database in
      try WalletSyncStateRow(state: state).save(database)
    }
  }

  func delete(accountId: UUID) async throws {
    try await database.write { database in
      _ =
        try WalletSyncStateRow
        .filter(WalletSyncStateRow.Columns.accountId == accountId)
        .deleteAll(database)
    }
  }
}
