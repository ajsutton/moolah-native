// Shared/CryptoImport/WalletImportRulesEngine.swift
import Foundation

/// Rules pass over a batch of fully-built crypto-imported transactions.
/// Distinct from the CSV `ImportRulesEngine` (which evaluates rules
/// against `ParsedTransaction` raw fields pre-build) — wallet-imported
/// transactions arrive at the apply engine already structured, with
/// resolved instruments and on-chain `externalId`s on every leg, so the
/// rules pass operates on `Transaction` directly.
///
/// `Sendable` so it can be supplied to the `@MainActor`
/// `WalletApplyEngine` from a non-isolated factory.
///
/// v1 of the apply pass ships with a no-op implementation; richer
/// rules — payee normalisation, category assignment from token / address
/// patterns — land in a follow-up alongside the wallet import-rules UI.
protocol WalletImportRulesEngine: Sendable {
  /// Returns the input transactions, possibly modified by rule actions
  /// (assigned payee, category, notes). The default implementation
  /// returns the input unchanged so apply-pipeline tests don't need to
  /// stub a no-op explicitly.
  func apply(transactions: [Transaction]) async throws -> [Transaction]
}

/// No-op implementation. Returns the input unchanged.
struct NoOpWalletImportRulesEngine: WalletImportRulesEngine {
  func apply(transactions: [Transaction]) async throws -> [Transaction] {
    transactions
  }
}
