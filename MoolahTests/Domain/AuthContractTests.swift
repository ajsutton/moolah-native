import Testing

@testable import Moolah

/// Contract tests that every AuthProvider implementation must satisfy.
/// InMemoryAuthProvider must pass these tests to prove substitutability
/// per the architecture contract.
@Suite("AuthProvider contract")
enum AuthContractTests {
  // MARK: - InMemoryAuthProvider

  @Suite("InMemoryAuthProvider")
  struct InMemoryTests {
    @Test("starts signed out by default")
    func startsSignedOut() async throws {
      let provider = InMemoryAuthProvider()
      let user = try await provider.currentUser()
      #expect(user == nil)
    }

    @Test("starts signed in when seeded with a profile")
    func startsSignedIn() async throws {
      let profile = UserProfile(id: "u1", pictureURL: nil)
      let provider = InMemoryAuthProvider(signedIn: profile)
      let user = try await provider.currentUser()
      #expect(user == profile)
    }

    @Test("signIn returns a user and persists it")
    func signIn() async throws {
      let provider = InMemoryAuthProvider()
      let user = try await provider.signIn()
      #expect(user.id.isEmpty == false)
      let current = try await provider.currentUser()
      #expect(current == user)
    }

    @Test("signOut clears the current user")
    func signOut() async throws {
      let provider = InMemoryAuthProvider(
        signedIn: UserProfile(id: "u1", pictureURL: nil))
      try await provider.signOut()
      let user = try await provider.currentUser()
      #expect(user == nil)
    }

    @Test("requiresExplicitSignIn defaults to true")
    func requiresExplicitSignIn() {
      #expect(InMemoryAuthProvider().requiresExplicitSignIn == true)
    }

    @Test("requiresExplicitSignIn respects constructor parameter")
    func requiresExplicitSignInFalse() {
      #expect(InMemoryAuthProvider(requiresExplicitSignIn: false).requiresExplicitSignIn == false)
    }
  }

  // MARK: - CloudKitAuthProvider

  @Suite("CloudKitAuthProvider")
  struct CloudKitTests {
    @Test("CloudKitAuthProvider does not require explicit sign in")
    func testCloudKitNoExplicitSignIn() {
      let auth = CloudKitAuthProvider(profileLabel: "Test")
      #expect(auth.requiresExplicitSignIn == false)
    }
  }
}
