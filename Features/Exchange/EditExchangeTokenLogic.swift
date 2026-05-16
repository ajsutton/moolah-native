// Features/Exchange/EditExchangeTokenLogic.swift
import Foundation

/// Applies an edit-account token replacement for an exchange account.
///
/// No `@MainActor`: this is a pure synchronous keychain call with no
/// main-actor state; isolating it would force non-main callers to await
/// a synchronous function for no reason. `ExchangeTokenStore` is
/// `Sendable`. Takes the `ExchangeTokenStoring` protocol (not the
/// concrete store) so the edit-account tests can inject a double; the
/// production `ExchangeTokenStore` conforms.
enum EditExchangeTokenLogic {
  /// Replaces the stored read-only token for `accountId`. An empty or
  /// whitespace-only `newToken` is a no-op so the user can save other
  /// edits without re-entering the token (matching the field's
  /// "leave blank to keep the existing token" copy). Trims with the
  /// same `.whitespacesAndNewlines` set as `ExchangeAccountCreationLogic`.
  static func applyTokenChange(
    newToken: String, accountId: UUID, tokenStore: any ExchangeTokenStoring
  ) throws {
    let trimmed = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    try tokenStore.save(token: trimmed, for: accountId)
  }
}
