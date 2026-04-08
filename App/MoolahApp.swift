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
      .disabled(newEarmarkAction == nil)
    }
  }
}

@main
@MainActor
struct MoolahApp: App {
  private let container: ModelContainer
  private let backend: BackendProvider
  private let authStore: AuthStore
  private let accountStore: AccountStore
  private let transactionStore: TransactionStore
  private let categoryStore: CategoryStore
  private let earmarkStore: EarmarkStore
  private let analysisStore: AnalysisStore
  private let investmentStore: InvestmentStore

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
    self.transactionStore = TransactionStore(repository: remoteBackend.transactions)
    self.categoryStore = CategoryStore(repository: remoteBackend.categories)
    self.earmarkStore = EarmarkStore(repository: remoteBackend.earmarks)
    self.analysisStore = AnalysisStore(repository: remoteBackend.analysis)
    self.investmentStore = InvestmentStore(repository: remoteBackend.investments)

    // Adjust account and earmark balances locally after any transaction mutation
    self.transactionStore.onMutate = { [accountStore, earmarkStore] old, new in
      accountStore.applyTransactionDelta(old: old, new: new)
      earmarkStore.applyTransactionDelta(old: old, new: new)
    }
  }

  var body: some Scene {
    WindowGroup {
      AppRootView()
        .environment(authStore)
        .environment(accountStore)
        .environment(transactionStore)
        .environment(categoryStore)
        .environment(earmarkStore)
        .environment(analysisStore)
        .environment(investmentStore)
    }
    .modelContainer(container)
    .commands {
      NewTransactionCommands()
      NewEarmarkCommands()
    }
  }
}
