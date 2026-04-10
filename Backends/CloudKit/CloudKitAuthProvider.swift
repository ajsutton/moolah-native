import CloudKit
import Foundation

final class CloudKitAuthProvider: AuthProvider, Sendable {
  private let profileLabel: String

  nonisolated let requiresExplicitSignIn: Bool = false

  init(profileLabel: String) {
    self.profileLabel = profileLabel
  }

  func currentUser() async throws -> UserProfile? {
    let status = try await CKContainer.default().accountStatus()
    guard status == .available else { return nil }
    return UserProfile(
      id: "icloud-user",
      givenName: profileLabel,
      familyName: "",
      pictureURL: nil
    )
  }

  func signIn() async throws -> UserProfile {
    let status = try await CKContainer.default().accountStatus()
    guard status == .available else {
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
