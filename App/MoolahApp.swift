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
        let backend = RemoteBackend(baseURL: URL(string: "http://localhost:8080/api/")!)
        authStore = AuthStore(backend: backend)
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(authStore)
        }
        .modelContainer(container)
    }
}
