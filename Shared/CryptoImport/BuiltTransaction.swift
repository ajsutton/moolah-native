// Shared/CryptoImport/BuiltTransaction.swift
import Foundation

/// In-flight transaction candidate produced by the build phase. Not yet
/// persisted: Stage 7's `@MainActor` apply pass merges these across
/// accounts, dedups against existing legs, then writes through
/// `TransactionRepository`.
///
/// `originAccountId` is the account whose Alchemy fetch produced this
/// candidate — needed for the cross-account merge step (so an outbound
/// from account A and the matching inbound on account B can be paired
/// by `externalId` + opposing-sign quantities).
///
/// The `transaction` value is structurally complete: legs carry the
/// correct `externalId` (= on-chain `txHash`) and the right
/// `TransactionType` per leg. `ImportOrigin` is populated with the
/// raw fetch context.
struct BuiltTransaction: Sendable, Hashable {
  let originAccountId: UUID
  let transaction: Transaction
}
