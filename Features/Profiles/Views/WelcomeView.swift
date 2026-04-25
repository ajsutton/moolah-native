import OSLog
import SwiftUI

#if canImport(AppKit)
  import AppKit
#endif

#if canImport(UIKit)
  import UIKit
#endif

private let welcomeLogger = Logger(subsystem: "com.moolah.app", category: "WelcomeView")

/// First-run state-machine view. Composes ``WelcomeHero``,
/// ``CreateProfileFormView``, ``ICloudProfilePickerView``, and
/// ``ICloudArrivalBanner``. Owns the interaction phase and the
/// banner-dismissed flag for this session.
///
/// State is resolved by ``WelcomeStateResolver`` so the branch logic is
/// unit-testable in isolation. See design spec §5.
struct WelcomeView: View {
  @Environment(ProfileStore.self) private var profileStore
  @Environment(SyncCoordinator.self) private var syncCoordinator

  @State private var phase: ProfileStore.WelcomePhase = .landing
  @State private var bannerDismissed = false
  @State private var hasEverDownloaded = false

  @State private var name = ""
  @State private var currency = Instrument.fiat(
    code: Locale.current.currency?.identifier ?? "AUD")
  @State private var financialYearStartMonth = 7

  var body: some View {
    let received = syncCoordinator.progress.recordsReceivedThisSession
    let state = WelcomeStateResolver.resolve(
      phase: phase,
      cloudProfilesCount: profileStore.cloudProfiles.count,
      iCloudAvailability: profileStore.iCloudAvailability,
      indexFetchedAtLeastOnce: syncCoordinator.profileIndexFetchedAtLeastOnce,
      bannerDismissed: bannerDismissed,
      recordsReceivedThisSession: received,
      wasDownloading: hasEverDownloaded
    )

    content(for: state)
      // macOS only: constrain the window to a compact range so the
      // hero / form / picker have a sensible layout envelope. Without
      // this, SwiftUI sizes the window from content ideal — unbounded
      // `Spacer()`s in the hero let it grow to full-screen, and at
      // small heights the CTA scrolls off the bottom.
      //
      // Minimum keeps the Get started button visible; ideal opens
      // at a friendly splash size on first appearance. `maxHeight:
      // .infinity` still lets the picker grow for long profile
      // lists or accessibility-sized text.
      //
      // iOS uses device-level sizing and keyboard avoidance; a
      // hard `minWidth: 420` would overflow iPhone widths.
      #if os(macOS)
        .frame(
          minWidth: 420,
          idealWidth: 500,
          maxWidth: .infinity,
          minHeight: 560,
          idealHeight: 720,
          maxHeight: .infinity
        )
      #endif
      .onAppear { profileStore.welcomePhase = phase }
      .onDisappear { profileStore.welcomePhase = nil }
      .onChange(of: phase) { _, newValue in
        profileStore.welcomePhase = newValue
      }
      .onChange(of: received) { _, newValue in
        if newValue > 0 { hasEverDownloaded = true }
      }
  }

  @ViewBuilder
  private func content(for state: WelcomeStateResolver.ResolvedState) -> some View {
    switch state {
    case .heroChecking:
      heroView(state: .checking)
    case .heroDownloading(let count):
      heroDownloadingView(received: count)
    case .heroNoneFound:
      heroView(state: .noneFound)
    case .heroOff(let reason):
      heroOffView(reason: reason)
    case .form(let banner):
      formView(banner: banner)
    case .picker:
      pickerView
    case .autoActivateSingle:
      Color.clear
        .task {
          guard let first = profileStore.cloudProfiles.first else { return }
          profileStore.setActiveProfile(first.id)
        }
    }
  }

  @ViewBuilder
  private func heroView(state: ICloudStatusLine.State) -> some View {
    // UI tests query the "Get started" button via `app.buttons["Get started"]`
    // (XCUITest label-based lookup) rather than by accessibility identifier —
    // applying `.accessibilityIdentifier` to the outer wrapper does not reach
    // the inner Button in SwiftUI's accessibility graph. The identifier
    // constant `UITestIdentifiers.Welcome.heroGetStartedButton` remains in
    // `UITestSupport/` for Task 17's screen driver to use if WelcomeHero
    // later exposes a tag parameter.
    WelcomeHero(
      mode: .checking,
      primaryAction: beginCreate,
      footer: { ICloudStatusLine(state: state) }
    )
  }

  @ViewBuilder
  private func heroDownloadingView(received: Int) -> some View {
    WelcomeHero(
      mode: .downloading(received: received),
      primaryAction: beginCreate,
      footer: { ICloudStatusLine(state: .checkingActive(received: received)) }
    )
  }

  private func heroOffView(
    reason: ICloudAvailability.UnavailableReason
  ) -> some View {
    // `ICloudOffChip` already labels the iCloud-off state for VoiceOver, so
    // the hero does not need its own overall `.accessibilityLabel(…)`. An
    // outer label here also collapses the inner `WelcomeHero` — including
    // its "Get started" `Button` — into a single accessibility element with
    // that label, which hides the primary CTA from label-based queries and
    // from individual VoiceOver focus.
    WelcomeHero(
      mode: .checking,
      primaryAction: beginCreate,
      footer: {
        ICloudOffChip(openSettingsAction: openSystemSettings)
          .accessibilityIdentifier(
            UITestIdentifiers.Welcome.iCloudOffSystemSettingsLink
          )
      }
    )
    .accessibilityHint(offHeroHint(for: reason))
  }

  private func formView(
    banner: WelcomeStateResolver.BannerKind?
  ) -> some View {
    let backgroundChecking =
      profileStore.iCloudAvailability == .available
      && !syncCoordinator.profileIndexFetchedAtLeastOnce

    return CreateProfileFormView(
      name: $name,
      currency: $currency,
      financialYearStartMonth: $financialYearStartMonth,
      banner: banner.map(mapBanner),
      onBannerPrimary: handleBannerPrimary,
      onBannerDismiss: { bannerDismissed = true },
      backgroundCheckingICloud: backgroundChecking,
      cancelAction: { phase = .landing },
      createAction: handleCreate
    )
  }

  private var pickerView: some View {
    ICloudProfilePickerView(
      profiles: profileStore.cloudProfiles,
      accountCounts: [:],
      selectAction: { profile in profileStore.setActiveProfile(profile.id) },
      createNewAction: {
        phase = .creating
        bannerDismissed = true  // user explicitly chose to create
      }
    )
  }

  // MARK: - Actions

  private func beginCreate() {
    #if os(iOS)
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    #endif
    phase = .creating
  }

  private func handleCreate() async {
    let trimmedName = name.trimmingCharacters(in: .whitespaces)
    guard !trimmedName.isEmpty else { return }
    guard profileStore.welcomePhase == .creating else {
      welcomeLogger.info("handleCreate aborted — phase changed under us")
      return
    }
    let profile = Profile(
      label: trimmedName,
      backendType: .cloudKit,
      currencyCode: currency.id,
      financialYearStartMonth: financialYearStartMonth
    )
    _ = await profileStore.validateAndAddProfile(profile)
  }

  private func handleBannerPrimary() {
    if profileStore.cloudProfiles.count == 1,
      let first = profileStore.cloudProfiles.first
    {
      profileStore.setActiveProfile(first.id)
    } else {
      phase = .pickingProfile
    }
  }

  private func openSystemSettings() {
    #if canImport(AppKit)
      let primary = URL(
        string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane"
      )
      if let primary, NSWorkspace.shared.open(primary) { return }
      NSWorkspace.shared.open(
        URL(fileURLWithPath: "/System/Applications/System Settings.app")
      )
    #elseif canImport(UIKit)
      if let url = URL(string: "App-Prefs:") {
        UIApplication.shared.open(url) { success in
          if !success {
            welcomeLogger.warning("Failed to open App-Prefs from iCloud-off chip")
          }
        }
      }
    #endif
  }

  private func mapBanner(
    _ kind: WelcomeStateResolver.BannerKind
  ) -> ICloudArrivalBanner.Kind {
    switch kind {
    case .singleArrived:
      return .single(label: profileStore.cloudProfiles.first?.label ?? "profile")
    case .multiArrived(let count):
      return .multiple(count: count)
    }
  }

  private func offHeroHint(
    for reason: ICloudAvailability.UnavailableReason
  ) -> String {
    switch reason {
    case .notSignedIn:
      return String(localized: "iCloud is not signed in.")
    case .restricted:
      return String(localized: "iCloud is restricted.")
    case .temporarilyUnavailable:
      return String(localized: "iCloud is temporarily unavailable.")
    case .entitlementsMissing:
      return String(localized: "iCloud is not available in this build.")
    }
  }
}
