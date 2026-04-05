import SwiftUI

/// Placeholder main content shown after sign-in. Replaced step-by-step with real screens.
struct ContentView: View {
    @Environment(AuthStore.self) private var authStore

    var body: some View {
        NavigationStack {
            VStack {
                Image(systemName: "dollarsign.circle")
                    .imageScale(.large)
                    .foregroundStyle(.tint)
                Text("Moolah")
                    .font(.largeTitle)
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    if case .signedIn(let user) = authStore.state {
                        UserMenuView(user: user)
                            .environment(authStore)
                    }
                }
            }
        }
    }
}
