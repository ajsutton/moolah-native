import SwiftData
import SwiftUI

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
  }

  var body: some Scene {
    WindowGroup {
      AppRootView()
        .environment(authStore)
        .environment(accountStore)
        .environment(transactionStore)
        .environment(categoryStore)
        .environment(earmarkStore)
    }
    .modelContainer(container)
  }
}
