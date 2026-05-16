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
/// rollback test injects a save-throwing double.
/// Scaffolding (no existing equivalent): an in-memory backend giving an
/// `AccountStore` + its `repository`, a token store (real device-local
/// `ExchangeTokenStore`, or a save-throwing double when
/// `failingTokenStore: true`), and an optional `SyncedAccountStore`.
/// File-scoped (not nested) to stay within SwiftLint's 1-level nesting.
@MainActor
private struct ExchangeCreationHarness {
  let accountStore: AccountStore
  let tokenStore: any ExchangeTokenStoring
  let syncStore: SyncedAccountStore?
  /// The real device-local store, when used, so the suite can clear
  /// keychain rows after each test.
  private let realTokenStore: ExchangeTokenStore?

  init(failingTokenStore: Bool = false) throws {
    let (backend, _) = try TestBackend.create()
    accountStore = AccountStore(
      repository: backend.accounts,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    if failingTokenStore {
      tokenStore = FailingExchangeTokenStore()
      realTokenStore = nil
    } else {
      let store = ExchangeTokenStore(synchronizable: false)
      tokenStore = store
      realTokenStore = store
    }
    syncStore = nil
  }

  func cleanUp(accountId: UUID) {
    realTokenStore?.delete(for: accountId)
  }
}

/// Save-throwing token-store double — proves the rollback path deletes
/// the just-created account so no "missing token" orphan is left.
private struct FailingExchangeTokenStore: ExchangeTokenStoring {
  func save(token: String, for accountId: UUID) throws {
    throw FailingExchangeTokenStoreError.saveFailed
  }

  func token(for accountId: UUID) throws -> String? { nil }

  func delete(for accountId: UUID) {}
}

private enum FailingExchangeTokenStoreError: Error {
  case saveFailed
}

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
    defer { harness.cleanUp(accountId: account.id) }
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
