import Testing
@testable import Moolah

@Suite("AuthStore")
@MainActor
struct AuthStoreTests {
    // MARK: - load()

    @Test("transitions loading → signedIn when currentUser returns a profile")
    func loadSignedIn() async {
        let profile = UserProfile(id: "u1", givenName: "Ada", familyName: "Lovelace", pictureURL: nil)
        let store = AuthStore(backend: InMemoryBackend(auth: InMemoryAuthProvider(signedIn: profile)))
        await store.load()
        guard case .signedIn(let user) = store.state else {
            Issue.record("Expected .signedIn, got \(store.state)")
            return
        }
        #expect(user == profile)
    }

    @Test("transitions loading → signedOut when currentUser returns nil")
    func loadSignedOut() async {
        let store = AuthStore(backend: InMemoryBackend(auth: InMemoryAuthProvider()))
        await store.load()
        #expect(store.state == .signedOut)
    }

    @Test("transitions signedIn → signedOut on signOut()")
    func signOut() async {
        let profile = UserProfile(id: "u1", givenName: "Ada", familyName: "Lovelace", pictureURL: nil)
        let store = AuthStore(backend: InMemoryBackend(auth: InMemoryAuthProvider(signedIn: profile)))
        await store.load()
        await store.signOut()
        #expect(store.state == .signedOut)
    }

    @Test("auth failure leaves store in signedOut with error message")
    func authFailure() async {
        let store = AuthStore(backend: InMemoryBackend(auth: FailingAuthProvider()))
        await store.load()
        #expect(store.state == .signedOut)
        #expect(store.errorMessage != nil)
    }

    // MARK: - requiresSignIn

    @Test("requiresSignIn reflects backend provider value when true")
    func requiresSignInTrue() {
        let store = AuthStore(backend: InMemoryBackend(auth: InMemoryAuthProvider(requiresExplicitSignIn: true)))
        #expect(store.requiresSignIn == true)
    }

    @Test("requiresSignIn reflects backend provider value when false")
    func requiresSignInFalse() {
        let store = AuthStore(backend: InMemoryBackend(auth: InMemoryAuthProvider(requiresExplicitSignIn: false)))
        #expect(store.requiresSignIn == false)
    }
}

// MARK: - Test helpers

/// AuthProvider that always throws on currentUser().
private struct FailingAuthProvider: AuthProvider {
    nonisolated let requiresExplicitSignIn = true

    func currentUser() async throws -> UserProfile? {
        throw BackendError.networkUnavailable
    }

    func signIn() async throws -> UserProfile {
        throw BackendError.networkUnavailable
    }

    func signOut() async throws {
        throw BackendError.networkUnavailable
    }
}
