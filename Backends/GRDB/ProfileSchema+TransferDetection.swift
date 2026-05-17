// Backends/GRDB/ProfileSchema+TransferDetection.swift

import Foundation
import GRDB

extension ProfileSchema {
  /// v12 migration body. Fuzzy-transfer-detection storage:
  ///
  /// - `transaction.transfer_suggestion_counterpart_id` (BLOB) +
  ///   `transaction.transfer_suggestion_suggested_at` (TEXT) — the
  ///   denormalised `TransferSuggestion`. NULL = no suggestion.
  /// - `transaction.import_origin_kind` (TEXT, CHECK IN
  ///   ('single','merged'), nullable). The decode rule: kind 'merged'
  ///   → the eight existing `import_origin_*` columns hold the OUTGOING
  ///   origin and the eight new `import_origin_incoming_*` columns hold
  ///   the INCOMING origin; kind 'single' OR NULL with the eight
  ///   existing columns populated → a single origin (NULL kind is the
  ///   pre-v12 legacy shape and reads back identically); everything
  ///   NULL → no origin.
  /// - Eight `import_origin_incoming_*` columns mirroring the existing
  ///   denormalised `ImportOrigin` shape for the merged incoming side.
  /// - `dismissed_transfer_pair` — synced (CKSyncEngine). `id` is a
  ///   content-addressed UUID of the unordered transaction-id pair, so
  ///   the repository's `upsert` on the PK is idempotent across devices.
  ///
  /// All additive; no table rebuild (no CHECK change to an existing
  /// column). Legacy rows: every new column NULL, read as "no
  /// suggestion / single (or no) import origin / not dismissed".
  static func addTransferDetection(_ database: Database) throws {
    try database.execute(
      sql: """
        ALTER TABLE "transaction" ADD COLUMN transfer_suggestion_counterpart_id BLOB;
        ALTER TABLE "transaction" ADD COLUMN transfer_suggestion_suggested_at TEXT;
        ALTER TABLE "transaction" ADD COLUMN import_origin_kind TEXT
            CHECK (import_origin_kind IS NULL
                   OR import_origin_kind IN ('single', 'merged'));
        ALTER TABLE "transaction" ADD COLUMN import_origin_incoming_raw_description TEXT;
        ALTER TABLE "transaction" ADD COLUMN import_origin_incoming_bank_reference TEXT;
        ALTER TABLE "transaction" ADD COLUMN import_origin_incoming_raw_amount TEXT;
        ALTER TABLE "transaction" ADD COLUMN import_origin_incoming_raw_balance TEXT;
        ALTER TABLE "transaction" ADD COLUMN import_origin_incoming_imported_at TEXT;
        ALTER TABLE "transaction" ADD COLUMN import_origin_incoming_import_session_id BLOB;
        ALTER TABLE "transaction" ADD COLUMN import_origin_incoming_source_filename TEXT;
        ALTER TABLE "transaction" ADD COLUMN import_origin_incoming_parser_identifier TEXT;

        -- WITHOUT ROWID intentionally NOT used: the repository writes via
        -- `upsert(database)`, which in GRDB 7 emits `RETURNING "rowid"`
        -- and fails against WITHOUT ROWID tables (the constraint that
        -- drove v4_rate_cache_without_rowid). ValueObservation change
        -- hooks also require a rowid table. Single small rows; the rowid
        -- overhead is negligible here.
        CREATE TABLE dismissed_transfer_pair (
            id                     BLOB    NOT NULL PRIMARY KEY,
            record_name            TEXT    NOT NULL UNIQUE,
            transaction_id_a       BLOB    NOT NULL,
            transaction_id_b       BLOB    NOT NULL,
            dismissed_at           TEXT    NOT NULL,
            encoded_system_fields  BLOB
        ) STRICT;

        -- `pairs(touching: id)` filters WHERE tx_a = ? OR tx_b = ?.
        -- SQLite resolves OR-of-two-indexed-columns via a two-scan
        -- union; both indexes are required and neither is a prefix of
        -- the other (different columns). Per DATABASE_SCHEMA_GUIDE §4.
        CREATE INDEX dismissed_pair_by_tx_a ON dismissed_transfer_pair(transaction_id_a);
        CREATE INDEX dismissed_pair_by_tx_b ON dismissed_transfer_pair(transaction_id_b);
        """)
  }
}
