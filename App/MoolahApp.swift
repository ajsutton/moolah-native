import SwiftUI
import SwiftData

@main
struct MoolahApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Schema([]))
        } catch {
            fatalError("Failed to initialize ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
