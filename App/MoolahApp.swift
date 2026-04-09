import SwiftData
import SwiftUI

/// Commands for creating new transactions
struct NewTransactionCommands: Commands {
  @FocusedValue(\.newTransactionAction) private var newTransactionAction

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Transaction") {
        newTransactionAction?()
      }
      .keyboardShortcut("n", modifiers: .command)
      .disabled(newTransactionAction == nil)
    }
  }
}

/// Commands for creating new earmarks
struct NewEarmarkCommands: Commands {
  @FocusedValue(\.newEarmarkAction) private var newEarmarkAction

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("New Earmark") {
        newEarmarkAction?()
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])
      .disabled(newEarmarkAction == nil)
    }
  }
}

/// Commands for refreshing data
struct RefreshCommands: Commands {
  @FocusedValue(\.refreshAction) private var refreshAction

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Divider()
      Button("Refresh") {
        refreshAction?()
      }
      .keyboardShortcut("r", modifiers: .command)
      .disabled(refreshAction == nil)
    }
  }
}

@main
@MainActor
struct MoolahApp: App {
  private let container: ModelContainer
  private let profileStore: ProfileStore
  @State private var activeSession: ProfileSession?

  init() {
    do {
      container = try ModelContainer(for: Schema([]))
    } catch {
      fatalError("Failed to initialize ModelContainer: \(error)")
    }
    self.profileStore = ProfileStore()
  }

  var body: some Scene {
    WindowGroup {
      ProfileRootView(activeSession: $activeSession)
        .environment(profileStore)
    }
    .modelContainer(container)
    .commands {
      NewTransactionCommands()
      NewEarmarkCommands()
      RefreshCommands()
    }
  }
}
