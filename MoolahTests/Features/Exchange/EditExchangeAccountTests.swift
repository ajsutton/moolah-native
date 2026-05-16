// MoolahTests/Features/Exchange/EditExchangeAccountTests.swift
import Foundation
import Testing

@testable import Moolah

/// Tests for `EditExchangeTokenLogic.applyTokenChange(...)` — the
/// edit-account affordance that lets a user replace a stored exchange
/// token (empty input = leave the existing token untouched).
///
/// Reuses the shared `ExchangeCreationHarness` to set up an exchange
/// account before exercising the edit path.
@Suite("EditExchangeTokenLogic — applyTokenChange")
@MainActor
struct EditExchangeAccountTests {
  @Test
  func replacingTokenUpdatesKeychainOnly() async throws {
    let harness = try ExchangeCreationHarness()
    let logic = ExchangeAccountCreationLogic(
      accountStore: harness.accountStore,
      tokenStore: harness.tokenStore,
      syncStore: nil,
      profileInstrument: .defaultTestInstrument)
    let outcome = await logic.submit(
      name: "Coinstash", provider: .coinstash, token: "OLD")
    guard case .created(let acct) = outcome else {
      Issue.record("Expected .created from logic.submit, got \(outcome)")
      return
    }
    defer { harness.cleanUpKeychain(for: acct.id) }

    try EditExchangeTokenLogic.applyTokenChange(
      token: "NEW", for: acct.id, using: harness.tokenStore)

    #expect(try harness.tokenStore.token(for: acct.id) == "NEW")
  }

  @Test
  func emptyTokenLeavesExistingUnchanged() throws {
    let harness = try ExchangeCreationHarness()
    let id = UUID()
    defer { harness.cleanUpKeychain(for: id) }
    try harness.tokenStore.save(token: "KEEP", for: id)

    try EditExchangeTokenLogic.applyTokenChange(
      token: "  ", for: id, using: harness.tokenStore)

    #expect(try harness.tokenStore.token(for: id) == "KEEP")
  }
}
