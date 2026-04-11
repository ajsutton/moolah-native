import Foundation

final class CloudKitAuthProvider: AuthProvider, Sendable {
  private let profileLabel: String

  nonisolated let requiresExplicitSignIn: Bool = false

  init(profileLabel: String) {
    self.profileLabel = profileLabel
  }

  func currentUser() async throws -> UserProfile? {
    // iCloud profiles use implicit auth via the device's Apple ID.
    // No CKContainer check — SwiftData works locally even without
    // CloudKit entitlements, and CKContainer.default() crashes with
    // an NSException if no container is configured.
    UserProfile(
      id: "icloud-user",
      givenName: profileLabel,
      familyName: "",
      pictureURL: nil
    )
  }

  func signIn() async throws -> UserProfile {
    guard FileManager.default.ubiquityIdentityToken != nil else {
      throw BackendError.unauthenticated
    }
    return UserProfile(
      id: "icloud-user",
      givenName: profileLabel,
      familyName: "",
      pictureURL: nil
    )
  }

  func signOut() async throws {
    // No-op — cannot sign out of iCloud programmatically
  }
}
