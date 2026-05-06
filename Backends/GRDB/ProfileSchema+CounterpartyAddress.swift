// Backends/GRDB/ProfileSchema+CounterpartyAddress.swift

import Foundation
import GRDB

extension ProfileSchema {
  /// v9 migration body. Adds `counterparty_address` to `transaction_leg`.
  ///
  /// Additive optional column — legacy rows (existing `transaction_leg`
  /// rows from pre-v9 builds) decode with `nil` because SQLite gives
  /// freshly added nullable columns the value `NULL` for every existing
  /// row. The mapping layer (`TransactionLegRow+Mapping.swift`) treats
  /// `nil` as the "no counterparty recorded" case, which is the correct
  /// semantics for everything that pre-dates the wallet importer.
  ///
  /// No index. The field is informational on the leg (surfaced in the
  /// transaction detail) and isn't on any read path that would benefit
  /// from a SQLite index — counterparty filtering happens in-memory at
  /// the moment, and if/when a counterparty index is justified by
  /// query traces it lands as a separate migration with a
  /// purpose-shaped predicate.
  ///
  /// No CHECK. Address shape is enforced upstream by the wallet
  /// importer (Alchemy returns lowercased hex), and the storage layer
  /// stays liberal so non-EVM chains (which may use bech32, base58, or
  /// other encodings) can land without a schema migration.
  static func addCounterpartyAddressToTransactionLeg(_ database: Database) throws {
    try database.execute(
      sql: """
        ALTER TABLE transaction_leg ADD COLUMN counterparty_address TEXT;
        """)
  }
}
