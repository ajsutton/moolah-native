// MoolahTests/Features/Exchange/ExchangeAccountCreationLogicTests.swift
import Foundation
import Testing

@testable import Moolah

/// End-to-end tests for `ExchangeAccountCreationLogic.submit(...)`.
///
/// Drives the create-account + store-token + kick-off-sync sequence
/// through a real `AccountStore` backed by `TestBackend`. The token
/// store is the only seam — the happy path uses a real
/// `ExchangeTokenStore(synchronizable: false)` (device-local keychain,
/// no entitlement) so token round-tripping is genuinely exercised; the
/// rollback test injects a save-throwing double. Scaffolding is the
/// shared `ExchangeCreationHarness`.
@Suite("ExchangeAccountCreationLogic — submit")
@MainActor
struct ExchangeAccountCreationLogicTests {
  @Test
  func createsExchangeAccountAndStoresToken() async throws {
    let harness = try ExchangeCreationHarness()
    let logic = ExchangeAccountCreationLogic(
      accountStore: harness.accountStore,
      tokenStore: harness.tokenStore,
      syncStore: harness.syncStore,
      profileInstrument: .defaultTestInstrument)

    let outcome = await logic.submit(
      name: "My Coinstash", provider: .coinstash, token: "TOK123")

    guard case .created(let account) = outcome else {
      Issue.record("expected .created, got \(outcome)")
      return
    }
    defer { harness.cleanUpKeychain(for: account.id) }
    #expect(account.type == .exchange)
    #expect(account.exchangeProvider == .coinstash)
    #expect(account.instrument == .defaultTestInstrument)
    #expect(try harness.tokenStore.token(for: account.id) == "TOK123")
  }

  @Test
  func rejectsEmptyToken() async throws {
    let harness = try ExchangeCreationHarness()
    let logic = ExchangeAccountCreationLogic(
      accountStore: harness.accountStore,
      tokenStore: harness.tokenStore,
      syncStore: harness.syncStore,
      profileInstrument: .defaultTestInstrument)

    let outcome = await logic.submit(
      name: "X", provider: .coinstash, token: "  ")

    guard case .invalidInput = outcome else {
      Issue.record("expected .invalidInput, got \(outcome)")
      return
    }
    let accounts = try await harness.accountStore.repository.fetchAll()
    #expect(accounts.isEmpty)
  }

  @Test
  func tokenSaveFailureRollsBackTheCreatedAccount() async throws {
    let harness = try ExchangeCreationHarness(failingTokenStore: true)
    let logic = ExchangeAccountCreationLogic(
      accountStore: harness.accountStore,
      tokenStore: harness.tokenStore,
      syncStore: harness.syncStore,
      profileInstrument: .defaultTestInstrument)

    let outcome = await logic.submit(
      name: "C", provider: .coinstash, token: "TOK")

    guard case .failure = outcome else {
      Issue.record("expected .failure, got \(outcome)")
      return
    }
    // The just-created account must NOT survive (visibly) a token-save
    // failure — an account with no token is stuck "missing token"
    // forever. `AccountStore.delete(id:)` is the codebase-wide
    // soft-delete (flips `isHidden`), so the row remains in `fetchAll()`
    // but is hidden from the user exactly like any other deleted
    // account: assert no *visible* exchange account is left behind.
    let accounts = try await harness.accountStore.repository.fetchAll()
    #expect(!accounts.contains { $0.type == .exchange && !$0.isHidden })
  }
}
