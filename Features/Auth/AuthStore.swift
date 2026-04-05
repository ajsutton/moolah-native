import Observation

/// Manages authentication state. Injected into the SwiftUI environment at the composition root.
@Observable
@MainActor
final class AuthStore {
    enum State: Equatable {
        case loading
        case signedOut
        case signedIn(UserProfile)
    }

    private(set) var state: State = .loading
    private(set) var errorMessage: String?

    /// Whether the active backend requires an explicit sign-in gesture.
    var requiresSignIn: Bool { backend.auth.requiresExplicitSignIn }

    private let backend: any BackendProvider

    init(backend: any BackendProvider) {
        self.backend = backend
    }

    func load() async {
        do {
            if let user = try await backend.auth.currentUser() {
                state = .signedIn(user)
            } else {
                state = .signedOut
            }
        } catch {
            state = .signedOut
            errorMessage = error.localizedDescription
        }
    }

    func signIn() async {
        do {
            let user = try await backend.auth.signIn()
            state = .signedIn(user)
            errorMessage = nil
        } catch {
            state = .signedOut
            errorMessage = error.localizedDescription
        }
    }

    func signOut() async {
        do {
            try await backend.auth.signOut()
            state = .signedOut
            errorMessage = nil
        } catch {
            state = .signedOut
            errorMessage = error.localizedDescription
        }
    }
}
