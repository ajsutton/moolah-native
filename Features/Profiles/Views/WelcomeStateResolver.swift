import Foundation

/// Pure-logic resolver for ``WelcomeView``'s state machine. Extracted
/// so every branch is unit-testable without SwiftUI. Inputs are value
/// types so this can stay nonisolated.
enum WelcomeStateResolver {
  enum ResolvedState: Equatable {
    case heroChecking
    case heroDownloading(received: Int)
    case heroNoneFound
    case heroOff(reason: ICloudAvailability.UnavailableReason)
    case form(banner: BannerKind?)
    case picker
    case autoActivateSingle
  }

  enum BannerKind: Equatable {
    case singleArrived
    case multiArrived(count: Int)
  }

  static func resolve(
    phase: ProfileStore.WelcomePhase,
    profileCount: Int,
    iCloudAvailability: ICloudAvailability,
    indexFetchedAtLeastOnce: Bool,
    bannerDismissed: Bool,
    recordsReceivedThisSession: Int = 0,
    wasDownloading: Bool = false
  ) -> ResolvedState {
    switch phase {
    case .pickingProfile:
      return .picker

    case .creating:
      return resolveCreating(
        profileCount: profileCount,
        bannerDismissed: bannerDismissed
      )

    case .landing:
      return resolveLanding(
        profileCount: profileCount,
        iCloudAvailability: iCloudAvailability,
        indexFetchedAtLeastOnce: indexFetchedAtLeastOnce,
        recordsReceivedThisSession: recordsReceivedThisSession,
        wasDownloading: wasDownloading
      )
    }
  }

  private static func resolveCreating(
    profileCount: Int,
    bannerDismissed: Bool
  ) -> ResolvedState {
    if bannerDismissed || profileCount == 0 {
      return .form(banner: nil)
    }
    if profileCount == 1 {
      return .form(banner: .singleArrived)
    }
    return .form(banner: .multiArrived(count: profileCount))
  }

  private static func resolveLanding(
    profileCount: Int,
    iCloudAvailability: ICloudAvailability,
    indexFetchedAtLeastOnce: Bool,
    recordsReceivedThisSession: Int,
    wasDownloading: Bool
  ) -> ResolvedState {
    if profileCount == 1 {
      return .autoActivateSingle
    }
    if profileCount >= 2 {
      return .picker
    }
    if case .unavailable(let reason) = iCloudAvailability {
      return .heroOff(reason: reason)
    }
    if indexFetchedAtLeastOnce {
      return .heroNoneFound
    }
    if wasDownloading || recordsReceivedThisSession > 0 {
      return .heroDownloading(received: recordsReceivedThisSession)
    }
    return .heroChecking
  }
}
