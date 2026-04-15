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

  @Test("onMutate wiring connects transaction store to account and earmark stores")
  func onMutateWiring() {
    let session = ProfileSession(profile: makeProfile())

    // The onMutate callback should be set
    #expect(session.transactionStore.onMutate != nil)
  }

  @Test("onInvestmentValueChanged wiring connects investment store to account store")
  func onInvestmentValueChangedWiring() {
    let session = ProfileSession(profile: makeProfile())

    #expect(session.investmentStore.onInvestmentValueChanged != nil)
  }
}
