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

  @Test("AccountRecord change reloads the account store")
  func accountRecordReloadsAccounts() {
    let plan = ProfileSession.storesToReload(for: [AccountRow.recordType])
    #expect(plan == .accounts)
  }

  @Test("TransactionRecord change reloads the account store")
  func transactionRecordReloadsAccounts() {
    let plan = ProfileSession.storesToReload(for: [TransactionRow.recordType])
    #expect(plan == .accounts)
  }

  @Test("TransactionLegRecord change reloads both accounts and earmarks")
  func transactionLegRecordReloadsAccountsAndEarmarks() {
    // Regression for issue #76: leg-only remote changes (e.g. category or
    // earmark reassignment on another device) must trigger reloads of both
    // the account store and the earmark store, even when the parent
    // TransactionRecord did not change in this batch.
    let plan = ProfileSession.storesToReload(for: [TransactionLegRow.recordType])
    #expect(plan.contains(.accounts))
    #expect(plan.contains(.earmarks))
    #expect(!plan.contains(.categories))
  }

  @Test("CategoryRecord change reloads only the category store")
  func categoryRecordReloadsCategories() {
    let plan = ProfileSession.storesToReload(for: [CategoryRow.recordType])
    #expect(plan == .categories)
  }

  @Test("EarmarkRecord change reloads the earmark store")
  func earmarkRecordReloadsEarmarks() {
    let plan = ProfileSession.storesToReload(for: [EarmarkRow.recordType])
    #expect(plan == .earmarks)
  }

  @Test("EarmarkBudgetItemRecord change reloads the earmark store")
  func earmarkBudgetItemRecordReloadsEarmarks() {
    let plan = ProfileSession.storesToReload(for: [EarmarkBudgetItemRow.recordType])
    #expect(plan == .earmarks)
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

  @Test("Mixed record types combine reload plans")
  func mixedRecordTypesCombineReloadPlans() {
    let plan = ProfileSession.storesToReload(
      for: [
        TransactionLegRow.recordType,
        CategoryRow.recordType,
      ])
    #expect(plan.contains(.accounts))
    #expect(plan.contains(.earmarks))
    #expect(plan.contains(.categories))
  }
}
