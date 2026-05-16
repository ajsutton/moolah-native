// Features/Exchange/EditExchangeTokenLogic.swift
import Foundation

/// Applies an edit-account token replacement for an exchange account.
///
/// Not @MainActor: a pure synchronous keychain call with no main-actor
/// state. `ExchangeTokenStore` is `Sendable`, so off-main callers can
/// call this directly without an await.
enum EditExchangeTokenLogic {
  /// Saves a replacement read-only token for the account, or does nothing when
  /// the input is blank.
  ///
  /// A blank/whitespace token is a deliberate no-op (not an error): the edit
  /// form treats an empty field as "keep the existing token", so the user can
  /// save other account changes without re-entering the secret.
  ///
  /// - Throws: a keychain error if the (non-blank) token cannot be written
  ///   (e.g. the keychain is inaccessible or the item is locked).
  static func applyTokenChange(
    token newToken: String,
    for accountId: UUID,
    using tokenStore: any ExchangeTokenStoring
  ) throws {
    let trimmed = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    try tokenStore.save(token: trimmed, for: accountId)
  }
}
