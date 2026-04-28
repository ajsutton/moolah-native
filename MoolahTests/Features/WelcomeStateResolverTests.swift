import Foundation
import Testing

@testable import Moolah

@Suite("WelcomeStateResolver")
struct WelcomeStateResolverTests {

  @Test("landing, no cloud profiles, available → .heroChecking")
  func heroChecking() {
    let state = WelcomeStateResolver.resolve(
      phase: .landing,
      profileCount: 0,
      iCloudAvailability: .available,
      indexFetchedAtLeastOnce: false,
      bannerDismissed: false
    )
    #expect(state == .heroChecking)
  }

  @Test("landing, no cloud profiles, available, index fetched once → .heroNoneFound")
  func heroNoneFound() {
    let state = WelcomeStateResolver.resolve(
      phase: .landing,
      profileCount: 0,
      iCloudAvailability: .available,
      indexFetchedAtLeastOnce: true,
      bannerDismissed: false
    )
    #expect(state == .heroNoneFound)
  }

  @Test("landing, unavailable → .heroOff")
  func heroOff() {
    let state = WelcomeStateResolver.resolve(
      phase: .landing,
      profileCount: 0,
      iCloudAvailability: .unavailable(reason: .notSignedIn),
      indexFetchedAtLeastOnce: false,
      bannerDismissed: false
    )
    #expect(state == .heroOff(reason: .notSignedIn))
  }

  @Test("landing, 1 cloud profile → .autoActivateSingle")
  func autoActivateSingle() {
    let state = WelcomeStateResolver.resolve(
      phase: .landing,
      profileCount: 1,
      iCloudAvailability: .available,
      indexFetchedAtLeastOnce: true,
      bannerDismissed: false
    )
    #expect(state == .autoActivateSingle)
  }

  @Test("landing, 2+ cloud profiles → .picker")
  func pickerFromLanding() {
    let state = WelcomeStateResolver.resolve(
      phase: .landing,
      profileCount: 2,
      iCloudAvailability: .available,
      indexFetchedAtLeastOnce: true,
      bannerDismissed: false
    )
    #expect(state == .picker)
  }

  @Test("creating, no cloud profiles → .form (no banner)")
  func formNoBanner() {
    let state = WelcomeStateResolver.resolve(
      phase: .creating,
      profileCount: 0,
      iCloudAvailability: .available,
      indexFetchedAtLeastOnce: false,
      bannerDismissed: false
    )
    #expect(state == .form(banner: nil))
  }

  @Test("creating, 1 cloud profile, not dismissed → .form(single banner)")
  func formSingleBanner() {
    let state = WelcomeStateResolver.resolve(
      phase: .creating,
      profileCount: 1,
      iCloudAvailability: .available,
      indexFetchedAtLeastOnce: true,
      bannerDismissed: false
    )
    #expect(state == .form(banner: .singleArrived))
  }

  @Test("creating, 3 cloud profiles, not dismissed → .form(multi banner)")
  func formMultiBanner() {
    let state = WelcomeStateResolver.resolve(
      phase: .creating,
      profileCount: 3,
      iCloudAvailability: .available,
      indexFetchedAtLeastOnce: true,
      bannerDismissed: false
    )
    #expect(state == .form(banner: .multiArrived(count: 3)))
  }

  @Test("creating, 1 cloud profile, banner dismissed → .form (no banner)")
  func formSuppressesDismissedBanner() {
    let state = WelcomeStateResolver.resolve(
      phase: .creating,
      profileCount: 1,
      iCloudAvailability: .available,
      indexFetchedAtLeastOnce: true,
      bannerDismissed: true
    )
    #expect(state == .form(banner: nil))
  }

  @Test("pickingProfile → .picker regardless of count")
  func pickerFromPickingPhase() {
    let state = WelcomeStateResolver.resolve(
      phase: .pickingProfile,
      profileCount: 1,
      iCloudAvailability: .available,
      indexFetchedAtLeastOnce: true,
      bannerDismissed: true
    )
    #expect(state == .picker)
  }

  // MARK: - heroDownloading

  @Test
  func resolveLandingShowsDownloadingWhenRecordsArrive() {
    let result = WelcomeStateResolver.resolve(
      phase: .landing,
      profileCount: 0,
      iCloudAvailability: .available,
      indexFetchedAtLeastOnce: false,
      bannerDismissed: false,
      recordsReceivedThisSession: 47,
      wasDownloading: false
    )
    #expect(result == .heroDownloading(received: 47))
  }

  @Test
  func resolveLandingStaysCheckingWhenNoRecordsYet() {
    let result = WelcomeStateResolver.resolve(
      phase: .landing,
      profileCount: 0,
      iCloudAvailability: .available,
      indexFetchedAtLeastOnce: false,
      bannerDismissed: false,
      recordsReceivedThisSession: 0,
      wasDownloading: false
    )
    #expect(result == .heroChecking)
  }

  @Test
  func resolveLandingStaysDownloadingOnceSeen() {
    // wasDownloading sticks even if the counter is zero (between sessions).
    let result = WelcomeStateResolver.resolve(
      phase: .landing,
      profileCount: 0,
      iCloudAvailability: .available,
      indexFetchedAtLeastOnce: false,
      bannerDismissed: false,
      recordsReceivedThisSession: 0,
      wasDownloading: true
    )
    #expect(result == .heroDownloading(received: 0))
  }

  @Test
  func resolveLandingICloudOffOverridesDownloading() {
    let result = WelcomeStateResolver.resolve(
      phase: .landing,
      profileCount: 0,
      iCloudAvailability: .unavailable(reason: .notSignedIn),
      indexFetchedAtLeastOnce: false,
      bannerDismissed: false,
      recordsReceivedThisSession: 47,
      wasDownloading: true
    )
    #expect(result == .heroOff(reason: .notSignedIn))
  }
}
