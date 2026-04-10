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

/// View menu toggle for showing hidden accounts and earmarks
struct ShowHiddenCommands: Commands {
  @FocusedValue(\.showHiddenAccounts) private var showHidden

  var body: some Commands {
    CommandGroup(after: .sidebar) {
      if let showHidden {
        Toggle("Show Hidden Accounts", isOn: showHidden)
          .keyboardShortcut("h", modifiers: [.command, .shift])
      }
    }
  }
}

@main
@MainActor
struct MoolahApp: App {
  @State private var profileStore = ProfileStore(validator: RemoteServerValidator())

  #if os(macOS)
    @State private var sessionManager = SessionManager()
  #else
    private let container: ModelContainer
    @State private var activeSession: ProfileSession?

    init() {
      do {
        container = try ModelContainer(for: Schema([]))
      } catch {
        fatalError("Failed to initialize ModelContainer: \(error)")
      }
    }
  #endif

  var body: some Scene {
    #if os(macOS)
      WindowGroup(for: Profile.ID.self) { $profileID in
        ProfileWindowView(profileID: profileID)
          .environment(profileStore)
          .environment(sessionManager)
      }
      .commands {
        ProfileCommands(profileStore: profileStore, sessionManager: sessionManager)
        NewTransactionCommands()
        NewEarmarkCommands()
        RefreshCommands()
        ShowHiddenCommands()
      }

      Settings {
        SettingsView()
          .environment(profileStore)
          .environment(sessionManager)
      }
    #else
      WindowGroup {
        ProfileRootView(activeSession: $activeSession)
          .environment(profileStore)
      }
      .modelContainer(container)
      .commands {
        NewTransactionCommands()
        NewEarmarkCommands()
        RefreshCommands()
        ShowHiddenCommands()
      }
    #endif
  }
}
