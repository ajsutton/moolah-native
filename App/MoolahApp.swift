import SwiftUI
import SwiftData

@main
@MainActor
struct MoolahApp: App {
    private let container: ModelContainer
    private let backend: BackendProvider
    private let authStore: AuthStore
    private let accountStore: AccountStore

    init() {
        do {
            container = try ModelContainer(for: Schema([]))
        } catch {
            fatalError("Failed to initialize ModelContainer: \(error)")
        }
        let remoteBackend = RemoteBackend(baseURL: URL(string: "http://localhost:8080/api/")!)
        self.backend = remoteBackend
        self.authStore = AuthStore(backend: remoteBackend)
        self.accountStore = AccountStore(repository: remoteBackend.accounts)
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(authStore)
                .environment(accountStore)
        }
        .modelContainer(container)
    }
}
