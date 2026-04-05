import AuthenticationServices
import Foundation

/// Authenticates via the Moolah REST server's Google OAuth endpoint using
/// ASWebAuthenticationSession — the sign-in browser stays inside the app.
///
/// Sign-in flow:
/// 1. Opens `<baseURL>googleauth?_native=1` in an ASWebAuthenticationSession.
///    The `?_native=1` param is preserved by the Bell OAuth plugin through the
///    Google OAuth dance (Bell stores it in an encrypted state cookie on the server).
/// 2. The server's Google OAuth handler checks `credentials.query._native` and,
///    when set, redirects to `moolah://auth/callback` instead of `/`.
/// 3. ASWebAuthenticationSession detects the `moolah://` scheme and closes
///    automatically, completing the sign-in without the user needing to tap Cancel.
/// 4. The session cookie set by the server is now in HTTPCookieStorage.shared
///    (shared with Safari / ASWebAuthenticationSession when not using ephemeral sessions).
/// 5. All subsequent URLSession.shared requests include the session cookie.
///
/// Fallback (canceledLogin):
/// If the user manually dismisses the browser before sign-in completes, or if
/// ASWebAuthenticationSession closes for any other reason, we catch canceledLogin
/// and still check currentUser() — if the OAuth round-trip completed the cookie
/// is already set and sign-in succeeds; otherwise we surface an unauthenticated error.
@MainActor
final class RemoteAuthProvider: NSObject, AuthProvider, ASWebAuthenticationPresentationContextProviding {
    nonisolated let requiresExplicitSignIn = true

    private let client: APIClient
    private var activeSession: ASWebAuthenticationSession?
    // Cached before the session starts so presentationAnchor can return it even
    // after the key window changes during teardown (NSWindow() with no arguments
    // is not a valid AppKit object and crashes on macOS).
    // nonisolated(unsafe) is safe here: written once on MainActor before the
    // session starts and only read by presentationAnchor, which Apple documents
    // as being called on the main thread.
    nonisolated(unsafe) private var anchorWindow: AnyObject?

    init(client: APIClient) {
        self.client = client
    }

    func currentUser() async throws -> UserProfile? {
        do {
            let data = try await client.get("auth/")
            let response = try JSONDecoder().decode(LoginStateResponse.self, from: data)
            guard response.loggedIn, let profile = response.profile else { return nil }
            return UserProfile(
                id: profile.userId,
                givenName: profile.givenName,
                familyName: profile.familyName,
                pictureURL: profile.picture.flatMap { URL(string: $0) }
            )
        } catch BackendError.unauthenticated {
            return nil
        }
    }

    func signIn() async throws -> UserProfile {
        // Append ?_native=1 so the server redirects to moolah://auth/callback after OAuth.
        var components = URLComponents(url: client.baseURL.appending(path: "googleauth"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "_native", value: "1")]
        let authURL = components.url!

        // Cache the presentation window now, on the main actor, so presentationAnchor
        // can return it safely even after the ASWebAuthenticationSession closes and
        // NSApp.keyWindow becomes nil.
        #if os(macOS)
        anchorWindow = NSApp.keyWindow ?? NSApp.windows.first
        #elseif os(iOS)
        anchorWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.keyWindow
        #endif

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let session = ASWebAuthenticationSession(
                    url: authURL,
                    callbackURLScheme: "moolah"
                ) { _, error in
                    Task { @MainActor [weak self] in
                        // Cancel before releasing: avoids ASWebAuthenticationSession
                        // internal teardown issues when the session is released from
                        // within its own completion handler on macOS.
                        self?.activeSession?.cancel()
                        self?.activeSession = nil
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
                session.presentationContextProvider = self
                // Share the cookie store with Safari so the session cookie is accessible
                // to URLSession.shared after the in-app browser completes.
                session.prefersEphemeralWebBrowserSession = false
                activeSession = session
                session.start()
            }
        } catch let error as ASWebAuthenticationSessionError
                where error.code == .canceledLogin {
            // User manually dismissed the browser. The server cookie is already set
            // if the OAuth round-trip completed, so currentUser() below will succeed.
        }

        guard let user = try await currentUser() else {
            throw BackendError.unauthenticated
        }
        return user
    }

    func signOut() async throws {
        _ = try await client.delete("auth/")
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        // anchorWindow was set on MainActor before the session started.
        return (anchorWindow as? UIWindow) ?? UIWindow()
        #elseif os(macOS)
        return (anchorWindow as? NSWindow) ?? NSApplication.shared.windows.first!
        #endif
    }
}

// MARK: - Private DTOs

private struct LoginStateResponse: Decodable {
    let loggedIn: Bool
    let profile: ProfilePayload?

    struct ProfilePayload: Decodable {
        let userId: String
        let givenName: String
        let familyName: String
        let picture: String?
    }
}
