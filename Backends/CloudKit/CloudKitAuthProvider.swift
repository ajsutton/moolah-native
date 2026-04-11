import CloudKit
import Foundation

final class CloudKitAuthProvider: AuthProvider, Sendable {
  private let profileLabel: String

  nonisolated let requiresExplicitSignIn: Bool = false

  init(profileLabel: String) {
    self.profileLabel = profileLabel
  }

  func currentUser() async throws -> UserProfile? {
    guard isCloudKitAvailable else {
      // CloudKit not configured — still allow local-only SwiftData access
      return UserProfile(
        id: "local-user",
        givenName: profileLabel,
        familyName: "",
        pictureURL: nil
      )
    }
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
    guard isCloudKitAvailable else {
      return UserProfile(
        id: "local-user",
        givenName: profileLabel,
        familyName: "",
        pictureURL: nil
      )
    }
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

  /// Whether CloudKit entitlements are configured.
  /// CKContainer.default() throws an uncatchable NSException without them.
  private var isCloudKitAvailable: Bool {
    let containers =
      Bundle.main.object(forInfoDictionaryKey: "NSUbiquitousContainers") as? [String: Any]
    return containers != nil && !containers!.isEmpty
  }
}
