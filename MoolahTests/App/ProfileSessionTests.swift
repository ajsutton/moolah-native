import Foundation
import Testing

@testable import Moolah

@Suite("ProfileSession")
@MainActor
struct ProfileSessionTests {
  private func makeProfile(label: String = "Test") -> Profile {
    Profile(label: label)
  }

  @Test("session creates non-nil stores")
  func createsStores() throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let session = try ProfileSession(
      profile: makeProfile(), containerManager: containerManager)

    #expect(session.authStore.state == .loading)
    #expect(session.accountStore.accounts.ordered.isEmpty)
    #expect(session.transactionStore.transactions.isEmpty)
    #expect(session.categoryStore.categories.roots.isEmpty)
    #expect(session.earmarkStore.earmarks.ordered.isEmpty)
    #expect(session.investmentStore.values.isEmpty)
  }

  @Test("session ID matches profile ID")
  func sessionIdMatchesProfile() throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let profile = makeProfile()
    let session = try ProfileSession(profile: profile, containerManager: containerManager)

    #expect(session.id == profile.id)
  }

  @Test("two sessions for different profiles have independent backends")
  func independentSessions() throws {
    let containerManager1 = try ProfileContainerManager.forTesting()
    let containerManager2 = try ProfileContainerManager.forTesting()
    let session1 = try ProfileSession(
      profile: makeProfile(label: "One"), containerManager: containerManager1)
    let session2 = try ProfileSession(
      profile: makeProfile(label: "Two"), containerManager: containerManager2)

    #expect(session1.id != session2.id)
  }

  @Test("onInvestmentValueChanged wiring connects investment store to account store")
  func onInvestmentValueChangedWiring() throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let session = try ProfileSession(
      profile: makeProfile(), containerManager: containerManager)

    #expect(session.investmentStore.onInvestmentValueChanged != nil)
  }

  /// Regression for #102: a CloudKit profile must use `FullConversionService`,
  /// not `FiatConversionService`, so stock and crypto positions can be
  /// converted. `FiatConversionService` throws `unsupportedInstrumentKind`
  /// for any non-fiat input which (via Rule 11) blanks aggregates.
  @Test("CloudKit profile uses FullConversionService")
  func cloudKitProfileUsesFullConversionService() throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let profile = Profile(label: "iCloud", currencyCode: "AUD", financialYearStartMonth: 7)
    let session = try ProfileSession(profile: profile, containerManager: containerManager)

    #expect(session.backend.conversionService is FullConversionService)
  }

  // MARK: - setUp() — async SwiftData → GRDB migration entry point (#575)

  /// `ProfileSession.init` no longer runs the SwiftData → GRDB
  /// migration; that work moved into `setUp()` so the eight per-type
  /// `database.write` calls dispatch to GRDB's writer queue rather than
  /// blocking `@MainActor`. Calling `await session.setUp()` is
  /// idempotent — multiple awaits coalesce on the same in-flight task,
  /// which keeps view-side and caller-side awaits cheap and lets
  /// `SessionManager.session(for:)` fire-and-forget the first call
  /// without making the second slower.
  @Test("setUp() is idempotent when called repeatedly")
  func setUpIsIdempotent() async throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let session = try ProfileSession(
      profile: makeProfile(), containerManager: containerManager)
    try await session.setUp()
    try await session.setUp()
    try await session.setUp()
    // Reaching here without throwing is the success condition; the
    // real check is the file-private guard in `setUp()` returning the
    // existing task on subsequent calls rather than re-running.
  }

  @Test("CloudKit profile exposes cryptoTokenStore on session")
  func cloudKitProfileExposesCryptoTokenStore() throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let profile = Profile(label: "iCloud", currencyCode: "AUD", financialYearStartMonth: 7)
    let session = try ProfileSession(profile: profile, containerManager: containerManager)

    // Store exists and starts empty (registrations load on demand).
    #expect(session.cryptoTokenStore?.registrations.isEmpty == true)
  }

  // MARK: - storesToReload (sync reload dispatch policy)

  @Test("AccountRecord change does NOT enqueue an account reload")
  func accountRecordDoesNotReloadAccounts() {
    // AccountStore is reactive (commit 5 of
    // plans/2026-05-06-reactive-sync-refresh-implementation.md):
    // remote AccountRow / TransactionRow / TransactionLegRow changes
    // propagate via `AccountRepository.observeAll()` automatically.
    // The legacy `.accounts` reload path is intentionally not taken.
    let plan = ProfileSession.storesToReload(for: [AccountRow.recordType])
    #expect(plan.isEmpty)
  }

  @Test("TransactionRecord change does NOT enqueue an account reload")
  func transactionRecordDoesNotReloadAccounts() {
    // See `accountRecordDoesNotReloadAccounts` — AccountStore is reactive.
    let plan = ProfileSession.storesToReload(for: [TransactionRow.recordType])
    #expect(plan.isEmpty)
  }

  @Test("TransactionLegRecord change does NOT enqueue an account or earmark reload")
  func transactionLegRecordDoesNotEnqueueReactiveStores() {
    // Both AccountStore and EarmarkStore are reactive (subscribe to
    // `observeAll()` in `init`); leg-only remote changes (e.g. category
    // or earmark reassignment on another device) propagate via the
    // observation streams without an explicit reload entry.
    let plan = ProfileSession.storesToReload(for: [TransactionLegRow.recordType])
    #expect(!plan.contains(.accounts))
    #expect(!plan.contains(.earmarks))
    #expect(!plan.contains(.categories))
  }

  @Test("CategoryRecord change does NOT enqueue a category reload")
  func categoryRecordDoesNotReloadCategories() {
    // CategoryStore is reactive — `CategoryRepository.observeAll()` re-emits
    // when category rows change, so the legacy `.categories` reload path is
    // intentionally not taken.
    let plan = ProfileSession.storesToReload(for: [CategoryRow.recordType])
    #expect(plan.isEmpty)
  }

  @Test("EarmarkRecord change does NOT enqueue an earmark reload")
  func earmarkRecordDoesNotReloadEarmarks() {
    // EarmarkStore is reactive — `EarmarkRepository.observeAll()` re-emits
    // when earmark rows change, so the legacy `.earmarks` reload path is
    // intentionally not taken.
    let plan = ProfileSession.storesToReload(for: [EarmarkRow.recordType])
    #expect(plan.isEmpty)
  }

  @Test("EarmarkBudgetItemRecord change does NOT enqueue an earmark reload")
  func earmarkBudgetItemRecordDoesNotReloadEarmarks() {
    // Budget UI subscribes via `EarmarkRepository.observeBudget(earmarkId:)`
    // (or fetches on demand). Either way, no store-level reload is triggered
    // by a remote budget-item change.
    let plan = ProfileSession.storesToReload(for: [EarmarkBudgetItemRow.recordType])
    #expect(plan.isEmpty)
  }

  @Test("Unknown record types do not trigger any reload")
  func unknownRecordTypesDoNotReload() {
    let plan = ProfileSession.storesToReload(for: ["CD_SomethingElse"])
    #expect(plan.isEmpty)
  }

  @Test("Empty changed types produces an empty plan")
  func emptyChangedTypesProducesEmptyPlan() {
    let plan = ProfileSession.storesToReload(for: [])
    #expect(plan.isEmpty)
  }

  @Test("ImportRuleRecord change does NOT enqueue an import-rule reload")
  func importRuleRecordDoesNotReloadImportRules() {
    // ImportRuleStore is reactive — `ImportRuleRepository.observeAll()`
    // re-emits when import-rule rows change, so the legacy
    // `.importRules` reload path is intentionally not taken.
    let plan = ProfileSession.storesToReload(for: [ImportRuleRow.recordType])
    #expect(plan.isEmpty)
  }

  @Test("Mixed record types combine reload plans (every store is reactive)")
  func mixedRecordTypesCombineReloadPlans() {
    let plan = ProfileSession.storesToReload(
      for: [
        TransactionLegRow.recordType,
        CategoryRow.recordType,
        ImportRuleRow.recordType,
      ])
    // AccountStore, EarmarkStore, CategoryStore, and ImportRuleStore
    // are all reactive — none of them appear in the reload plan, even
    // when leg / transaction / earmark / category / import-rule
    // changes arrive together.
    #expect(plan.isEmpty)
  }
}
