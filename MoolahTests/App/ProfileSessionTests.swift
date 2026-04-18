import Foundation
import Testing

@testable import Moolah

@Suite("ProfileSession")
@MainActor
struct ProfileSessionTests {
  private func makeProfile(
    label: String = "Test",
    url: String = "https://moolah.rocks/api/"
  ) -> Profile {
    Profile(label: label, serverURL: URL(string: url)!)
  }

  @Test("session creates non-nil stores")
  func createsStores() {
    let session = ProfileSession(profile: makeProfile())

    #expect(session.authStore.state == .loading)
    #expect(session.accountStore.accounts.ordered.isEmpty)
    #expect(session.transactionStore.transactions.isEmpty)
    #expect(session.categoryStore.categories.roots.isEmpty)
    #expect(session.earmarkStore.earmarks.ordered.isEmpty)
    #expect(session.investmentStore.values.isEmpty)
  }

  @Test("session ID matches profile ID")
  func sessionIdMatchesProfile() {
    let profile = makeProfile()
    let session = ProfileSession(profile: profile)

    #expect(session.id == profile.id)
  }

  @Test("two sessions for different profiles have independent backends")
  func independentSessions() {
    let session1 = ProfileSession(profile: makeProfile(label: "One", url: "https://one.com/api/"))
    let session2 = ProfileSession(profile: makeProfile(label: "Two", url: "https://two.com/api/"))

    // They should be separate instances
    #expect(session1.id != session2.id)
    #expect(session1.profile.resolvedServerURL != session2.profile.resolvedServerURL)
  }

  @Test("onInvestmentValueChanged wiring connects investment store to account store")
  func onInvestmentValueChangedWiring() {
    let session = ProfileSession(profile: makeProfile())

    #expect(session.investmentStore.onInvestmentValueChanged != nil)
  }

  /// Regression for #102: a CloudKit profile must use `FullConversionService`,
  /// not `FiatConversionService`, so stock and crypto positions can be
  /// converted. `FiatConversionService` throws `unsupportedInstrumentKind`
  /// for any non-fiat input which (via Rule 11) blanks aggregates.
  @Test("CloudKit profile uses FullConversionService")
  func cloudKitProfileUsesFullConversionService() throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let profile = Profile(
      label: "iCloud", backendType: .cloudKit,
      currencyCode: "AUD", financialYearStartMonth: 7
    )
    let session = ProfileSession(profile: profile, containerManager: containerManager)

    #expect(session.backend.conversionService is FullConversionService)
  }

  @Test("CloudKit profile exposes cryptoTokenStore on session")
  func cloudKitProfileExposesCryptoTokenStore() throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let profile = Profile(
      label: "iCloud", backendType: .cloudKit,
      currencyCode: "AUD", financialYearStartMonth: 7
    )
    let session = ProfileSession(profile: profile, containerManager: containerManager)

    // Store exists and starts empty (registrations load on demand).
    #expect(session.cryptoTokenStore.registrations.isEmpty)
  }

  // MARK: - storesToReload (sync reload dispatch policy)

  @Test("AccountRecord change reloads the account store")
  func accountRecordReloadsAccounts() {
    let plan = ProfileSession.storesToReload(for: [AccountRecord.recordType])
    #expect(plan == .accounts)
  }

  @Test("TransactionRecord change reloads the account store")
  func transactionRecordReloadsAccounts() {
    let plan = ProfileSession.storesToReload(for: [TransactionRecord.recordType])
    #expect(plan == .accounts)
  }

  @Test("TransactionLegRecord change reloads both accounts and earmarks")
  func transactionLegRecordReloadsAccountsAndEarmarks() {
    // Regression for issue #76: leg-only remote changes (e.g. category or
    // earmark reassignment on another device) must trigger reloads of both
    // the account store and the earmark store, even when the parent
    // TransactionRecord did not change in this batch.
    let plan = ProfileSession.storesToReload(for: [TransactionLegRecord.recordType])
    #expect(plan.contains(.accounts))
    #expect(plan.contains(.earmarks))
    #expect(!plan.contains(.categories))
  }

  @Test("CategoryRecord change reloads only the category store")
  func categoryRecordReloadsCategories() {
    let plan = ProfileSession.storesToReload(for: [CategoryRecord.recordType])
    #expect(plan == .categories)
  }

  @Test("EarmarkRecord change reloads the earmark store")
  func earmarkRecordReloadsEarmarks() {
    let plan = ProfileSession.storesToReload(for: [EarmarkRecord.recordType])
    #expect(plan == .earmarks)
  }

  @Test("EarmarkBudgetItemRecord change reloads the earmark store")
  func earmarkBudgetItemRecordReloadsEarmarks() {
    let plan = ProfileSession.storesToReload(for: [EarmarkBudgetItemRecord.recordType])
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
        TransactionLegRecord.recordType,
        CategoryRecord.recordType,
      ])
    #expect(plan.contains(.accounts))
    #expect(plan.contains(.earmarks))
    #expect(plan.contains(.categories))
  }
}
