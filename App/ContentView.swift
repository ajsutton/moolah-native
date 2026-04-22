import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Placeholder main content shown after sign-in. Replaced step-by-step with real screens.
struct ContentView: View {
  @Environment(AuthStore.self) private var authStore
  @Environment(ProfileSession.self) private var session
  @Environment(AccountStore.self) private var accountStore
  @Environment(TransactionStore.self) private var transactionStore
  @Environment(CategoryStore.self) private var categoryStore
  @Environment(EarmarkStore.self) private var earmarkStore
  @Environment(AnalysisStore.self) private var analysisStore
  @Environment(InvestmentStore.self) private var investmentStore
  @Environment(ReportingStore.self) private var reportingStore

  #if os(macOS)
    @State private var selection: SidebarSelection? = .analysis
  #else
    @State private var selection: SidebarSelection?
  #endif

  @Environment(\.pendingNavigation) private var pendingNavigationBinding
  @Environment(\.scenePhase) private var scenePhase
  @Environment(ImportStore.self) private var importStore
  @State private var showCreateEarmarkSheet = false
  @State private var showImportCSVPicker = false
  @State private var importError: String?

  var body: some View {
    NavigationSplitView {
      SidebarView(selection: $selection)
        .navigationSplitViewColumnWidth(min: 200, ideal: 280)
        .task {
          async let a: Void = accountStore.load()
          async let c: Void = categoryStore.load()
          async let e: Void = earmarkStore.load()
          async let b: Void = importStore.refreshBadge()
          // Start the folder watch (macOS FSEvents or, on iOS, the
          // catch-up scan) if the user has picked one. The call is a
          // no-op when no folder is configured.
          async let w: Void = session.startFolderWatch()
          _ = await (a, c, e, b, w)
        }
        .onChange(of: scenePhase) { _, newPhase in
          if newPhase == .active {
            Task {
              await importStore.refreshBadge()
              // iOS doesn't have FSEvents, so foreground-entry is the
              // natural place to re-scan the watched folder. macOS's
              // live watch handles this automatically, but re-scanning
              // on activate is cheap and covers the window-reopened case.
              await session.scanWatchedFolder()
            }
          }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCSVFile)) { note in
          guard let url = note.object as? URL else { return }
          Task { await ingestCSVFileURL(url) }
        }
        .toolbar {
          #if os(iOS)
            ToolbarItem(placement: .automatic) {
              if case .signedIn = authStore.state {
                UserMenuView()
                  .environment(authStore)
              }
            }
          #endif
        }
    } detail: {
      switch selection {
      case .account(let id):
        if let account = accountStore.accounts.by(id: id) {
          if account.type == .investment {
            InvestmentAccountView(
              account: account,
              accounts: accountStore.accounts,
              categories: categoryStore.categories,
              earmarks: earmarkStore.earmarks,
              investmentStore: investmentStore,
              transactionStore: transactionStore)
          } else {
            TransactionListView(
              title: account.name,
              filter: TransactionFilter(accountId: account.id),
              accounts: accountStore.accounts,
              categories: categoryStore.categories,
              earmarks: earmarkStore.earmarks,
              transactionStore: transactionStore,
              positions: accountStore.positions(for: account.id),
              positionsHostCurrency: account.instrument,
              positionsTitle: account.name,
              conversionService: session.backend.conversionService,
              supportsComplexTransactions: session.profile.supportsComplexTransactions)
          }
        }
      case .earmark(let id):
        if let earmark = earmarkStore.earmarks.by(id: id) {
          EarmarkDetailView(
            earmark: earmark,
            accounts: accountStore.accounts,
            categories: categoryStore.categories,
            earmarks: earmarkStore.earmarks,
            transactionStore: transactionStore,
            analysisRepository: analysisStore.repository)
        }
      case .recentlyAdded:
        RecentlyAddedView(backend: session.backend)
      case .allTransactions:
        TransactionListView(
          title: "All Transactions",
          filter: TransactionFilter(),
          accounts: accountStore.accounts,
          categories: categoryStore.categories,
          earmarks: earmarkStore.earmarks,
          transactionStore: transactionStore,
          supportsComplexTransactions: session.profile.supportsComplexTransactions)
      case .upcomingTransactions:
        UpcomingView(
          accounts: accountStore.accounts,
          categories: categoryStore.categories,
          earmarks: earmarkStore.earmarks,
          transactionStore: transactionStore)
      case .categories:
        CategoriesView(categoryStore: categoryStore)
      case .reports:
        ReportsView(
          reportingStore: reportingStore,
          categories: categoryStore.categories,
          accounts: accountStore.accounts,
          earmarks: earmarkStore.earmarks,
          transactionStore: transactionStore)
      case .analysis:
        AnalysisView(store: analysisStore)
      case nil:
        ContentUnavailableView(
          "Select an Account", systemImage: "sidebar.left",
          description: Text("Choose an account from the sidebar to view transactions."))
      }
    }
    .navigationSplitViewStyle(.balanced)
    .safeAreaInset(edge: .top, spacing: 0) {
      SyncStatusBanner()
    }
    .focusedSceneValue(\.newEarmarkAction) {
      showCreateEarmarkSheet = true
    }
    .focusedSceneValue(\.importCSVAction) {
      showImportCSVPicker = true
    }
    .focusedSceneValue(\.pasteCSVAction) {
      Task { await pasteCSVFromClipboard() }
    }
    .focusedSceneValue(\.refreshAction) {
      Task {
        async let a: Void = accountStore.load()
        async let c: Void = categoryStore.load()
        async let e: Void = earmarkStore.load()
        _ = await (a, c, e)
      }
    }
    .sheet(isPresented: $showCreateEarmarkSheet) {
      CreateEarmarkSheet(
        instrument: session.profile.instrument,
        supportsComplexTransactions: session.profile.supportsComplexTransactions,
        onCreate: { newEarmark in
          Task {
            _ = await earmarkStore.create(newEarmark)
            showCreateEarmarkSheet = false
          }
        }
      )
    }
    .onChange(of: pendingNavigationBinding?.wrappedValue) { _, newValue in
      if let navigation = newValue {
        applyNavigation(navigation.destination)
        pendingNavigationBinding?.wrappedValue = nil
      }
    }
    .fileImporter(
      isPresented: $showImportCSVPicker,
      allowedContentTypes: [.commaSeparatedText, .plainText],
      allowsMultipleSelection: true
    ) { result in
      Task {
        await handleImportPickerResult(result)
      }
    }
    .alert(
      "Import failed",
      isPresented: Binding(
        get: { importError != nil },
        set: { if !$0 { importError = nil } })
    ) {
      Button("OK") { importError = nil }
    } message: {
      Text(importError ?? "")
    }
  }

  private func pasteCSVFromClipboard() async {
    #if os(macOS)
      guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
        importError = "Nothing to paste."
        return
      }
    #else
      guard let text = UIPasteboard.general.string, !text.isEmpty else {
        importError = "Nothing to paste."
        return
      }
    #endif
    let data = Data(text.utf8)
    _ = await importStore.ingest(
      data: data,
      source: .paste(text: text, label: "Pasted CSV"))
    selection = .recentlyAdded
  }

  /// Ingest a CSV file URL received from "Open With Moolah" / Dock drop.
  /// Security-scoped resource access follows the same pattern as the
  /// file importer: `url` comes from the system and needs explicit
  /// scope start/stop.
  private func ingestCSVFileURL(_ url: URL) async {
    let didStart = url.startAccessingSecurityScopedResource()
    defer {
      if didStart { url.stopAccessingSecurityScopedResource() }
    }
    do {
      let data = try Data(contentsOf: url)
      _ = await importStore.ingest(
        data: data,
        source: .droppedFile(url: url, forcedAccountId: nil))
      selection = .recentlyAdded
    } catch {
      importError = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
    }
  }

  private func handleImportPickerResult(_ result: Result<[URL], Error>) async {
    switch result {
    case .success(let urls):
      for url in urls {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
          if didStart { url.stopAccessingSecurityScopedResource() }
        }
        do {
          let data = try Data(contentsOf: url)
          _ = await importStore.ingest(
            data: data,
            source: .pickedFile(url: url, securityScoped: didStart))
        } catch {
          importError = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
        }
      }
      selection = .recentlyAdded
    case .failure(let error):
      importError = error.localizedDescription
    }
  }

  private func applyNavigation(_ destination: URLSchemeHandler.Destination) {
    if let sidebarSelection = URLSchemeHandler.toSidebarSelection(destination) {
      selection = sidebarSelection
    }
    if case .analysis(let history, let forecast) = destination {
      if let history { analysisStore.historyMonths = history }
      if let forecast { analysisStore.forecastMonths = forecast }
    }
  }
}
