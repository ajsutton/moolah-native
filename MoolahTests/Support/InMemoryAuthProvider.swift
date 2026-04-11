import Foundation

@testable import Moolah

/// In-memory AuthProvider used in all feature tests.
/// Configurable starting state; signIn/signOut toggle state without any networking.
actor InMemoryAuthProvider: AuthProvider {
  nonisolated let requiresExplicitSignIn: Bool

  private var profile: UserProfile?

  /// - Parameters:
  ///   - signedIn: Pre-seeded profile, or nil to start signed out.
  ///   - requiresExplicitSignIn: Defaults to true; set false to test the no-sign-in-button path.
  init(signedIn: UserProfile? = nil, requiresExplicitSignIn: Bool = true) {
    self.profile = signedIn
    self.requiresExplicitSignIn = requiresExplicitSignIn
  }

  func currentUser() async throws -> UserProfile? {
    profile
  }

  func signIn() async throws -> UserProfile {
    let user =
      profile
      ?? UserProfile(
        id: "fixture-user",
        givenName: "Ada",
        familyName: "Lovelace",
        pictureURL: nil
      )
    profile = user
    return user
  }

  func signOut() async throws {
    profile = nil
  }
}
