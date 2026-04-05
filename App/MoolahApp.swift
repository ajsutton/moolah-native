import SwiftUI
import SwiftData

@main
@MainActor
struct MoolahApp: App {
    private let container: ModelContainer
    private let authStore: AuthStore

    init() {
        do {
            container = try ModelContainer(for: Schema([]))
        } catch {
            fatalError("Failed to initialize ModelContainer: \(error)")
        }
        let backend = RemoteBackend(baseURL: URL(string: "https://moolah.rocks/api/")!)
        authStore = AuthStore(backend: backend)
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(authStore)
                // Required on macOS: ASWebAuthenticationSession delivers the
                // moolah://auth/callback URL via the app's URL-handling machinery.
                // Without onOpenURL the system has nowhere to route the callback,
                // the session never completes, and the user is left staring at Safari.
                // ASWebAuthenticationSession intercepts the URL before this closure
                // runs, so the closure body is intentionally empty.
                .onOpenURL { _ in }
        }
        .modelContainer(container)
    }
}
