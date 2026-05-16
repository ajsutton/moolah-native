// MoolahTests/Features/Exchange/EditExchangeAccountTests.swift
import Foundation
import Testing

@testable import Moolah

/// Tests for `EditExchangeTokenLogic.applyTokenChange(...)` — the
/// edit-account affordance that lets a user replace a stored exchange
/// token (empty input = leave the existing token untouched).
///
/// `ExchangeCreationHarness` in `ExchangeAccountCreationLogicTests.swift`
/// is file-private, so this suite carries its own minimal scaffolding
/// (mirroring that harness's `accountStore` / `tokenStore` shape) to set
/// up an exchange account before exercising the edit path.
@MainActor
private struct ExchangeCreationHarness {
  let accountStore: AccountStore
  let tokenStore: any ExchangeTokenStoring
  private let realTokenStore: ExchangeTokenStore

  init() throws {
    let (backend, _) = try TestBackend.create()
    accountStore = AccountStore(
      repository: backend.accounts,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    let store = ExchangeTokenStore(synchronizable: false)
    tokenStore = store
    realTokenStore = store
  }

  func cleanUp(accountId: UUID) {
    realTokenStore.delete(for: accountId)
  }
}

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
    guard
      case .created(let acct) = await logic.submit(
        name: "Coinstash", provider: .coinstash, token: "OLD")
    else {
      Issue.record("setup failed")
      return
    }
    defer { harness.cleanUp(accountId: acct.id) }

    try EditExchangeTokenLogic.applyTokenChange(
      newToken: "NEW", accountId: acct.id, tokenStore: harness.tokenStore)

    #expect(try harness.tokenStore.token(for: acct.id) == "NEW")
  }

  @Test
  func emptyTokenLeavesExistingUnchanged() throws {
    let harness = try ExchangeCreationHarness()
    let id = UUID()
    defer { harness.cleanUp(accountId: id) }
    try harness.tokenStore.save(token: "KEEP", for: id)

    try EditExchangeTokenLogic.applyTokenChange(
      newToken: "  ", accountId: id, tokenStore: harness.tokenStore)

    #expect(try harness.tokenStore.token(for: id) == "KEEP")
  }
}
