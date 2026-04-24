import Foundation

/// Pure-logic resolver for ``WelcomeView``'s state machine. Extracted
/// so every branch is unit-testable without SwiftUI. Inputs are value
/// types so this can stay nonisolated.
enum WelcomeStateResolver {
  enum ResolvedState: Equatable {
    case heroChecking
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
    cloudProfilesCount: Int,
    iCloudAvailability: ICloudAvailability,
    indexFetchedAtLeastOnce: Bool,
    bannerDismissed: Bool
  ) -> ResolvedState {
    switch phase {
    case .pickingProfile:
      return .picker

    case .creating:
      return resolveCreating(
        cloudProfilesCount: cloudProfilesCount,
        bannerDismissed: bannerDismissed
      )

    case .landing:
      return resolveLanding(
        cloudProfilesCount: cloudProfilesCount,
        iCloudAvailability: iCloudAvailability,
        indexFetchedAtLeastOnce: indexFetchedAtLeastOnce
      )
    }
  }

  private static func resolveCreating(
    cloudProfilesCount: Int,
    bannerDismissed: Bool
  ) -> ResolvedState {
    if bannerDismissed || cloudProfilesCount == 0 {
      return .form(banner: nil)
    }
    if cloudProfilesCount == 1 {
      return .form(banner: .singleArrived)
    }
    return .form(banner: .multiArrived(count: cloudProfilesCount))
  }

  private static func resolveLanding(
    cloudProfilesCount: Int,
    iCloudAvailability: ICloudAvailability,
    indexFetchedAtLeastOnce: Bool
  ) -> ResolvedState {
    if cloudProfilesCount == 1 {
      return .autoActivateSingle
    }
    if cloudProfilesCount >= 2 {
      return .picker
    }
    if case .unavailable(let reason) = iCloudAvailability {
      return .heroOff(reason: reason)
    }
    return indexFetchedAtLeastOnce ? .heroNoneFound : .heroChecking
  }
}
