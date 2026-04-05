/// Abstracts authentication so backends can use Google OAuth, Apple ID, or any other mechanism.
protocol AuthProvider: Sendable {
    /// Whether the user must explicitly tap a sign-in button.
    /// REST backend: true (Google OAuth). A future CloudKit backend: false (implicit Apple ID).
    var requiresExplicitSignIn: Bool { get }

    /// Returns the currently authenticated user, or nil if signed out.
    func currentUser() async throws -> UserProfile?

    /// Initiates the sign-in flow and returns the authenticated user on success.
    func signIn() async throws -> UserProfile

    /// Signs out and clears any stored session.
    func signOut() async throws
}
