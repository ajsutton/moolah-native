import SwiftUI

/// Recently Added — landing page for CSV imports. Shows the Needs Setup /
/// Failed Files panel at the top and a session-grouped list of recently
/// imported transactions below. The time window picker is in the toolbar.
struct RecentlyAddedView: View {
  let backend: any BackendProvider
  @Environment(ImportStore.self) private var importStore
  @Environment(TransactionStore.self) private var transactionStore
  @State private var viewModel: RecentlyAddedViewModel?
  @State private var window: RecentlyAddedViewModel.Window = .last24Hours
  @State private var searchText: String = ""
  @State private var createRuleFromTransaction: Transaction?
  @State private var showingCreateRuleFromSearch: Bool = false
  @State private var transactionForDetail: Transaction?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      RecentlyAddedNeedsSetupPanel(backend: backend, staging: importStore.staging)
      mainContent
    }
    .navigationTitle("Recently Added")
    .dropDestination(for: URL.self) { urls, _ in
      Task { await ingestDroppedURLs(urls) }
      return !urls.isEmpty
    }
    .toolbar {
      ToolbarItem(placement: .automatic) {
        Picker("Time window", selection: $window) {
          ForEach(RecentlyAddedViewModel.Window.allCases) { windowOption in
            Text(windowOption.label).tag(windowOption)
          }
        }
        .pickerStyle(.menu)
        .accessibilityLabel("Time window")
      }
      // Create-rule-from-search affordance: visible only when the search
      // field is non-empty, matching the plan's Task 18.5 spec.
      if !searchText.isEmpty {
        ToolbarItem(placement: .automatic) {
          Button {
            showingCreateRuleFromSearch = true
          } label: {
            Label("Create rule matching this search", systemImage: "plus.rectangle.on.folder")
          }
        }
      }
    }
    .sheet(item: $createRuleFromTransaction) { transaction in
      CreateRuleFromTransactionSheet(
        transaction: transaction,
        corpus: corpusFromViewModel())
    }
    .sheet(isPresented: $showingCreateRuleFromSearch) {
      RecentlyAddedRuleFromSearchSheet(query: searchText)
    }
    .sheet(item: $transactionForDetail) { transaction in
      RecentlyAddedDetailSheet(transaction: transaction)
    }
    // `.task(id:)` fires on first appearance and re-fires (auto-cancelling
    // any in-flight load) whenever any of the tracked values change. We
    // combine `window` and `importStore.recentSessions.count` into a
    // single id so a finishSetup completion re-queries the backend with
    // the same cancellation hygiene the window-picker already had —
    // avoiding the unbounded `Task { … }` in `.onChange` that the
    // concurrency review flagged.
    .task(id: reloadKey) { await reload() }
  }

  /// Composite id for `.task(id:)` — re-fire the reload whenever the
  /// window changes OR `ImportStore.recentSessions` grows (i.e. an
  /// ingest completed). `recentSessions.count` is a stable proxy for
  /// "something new was imported" without us having to observe the
  /// session list itself.
  private struct ReloadKey: Hashable {
    let window: RecentlyAddedViewModel.Window
    let importedCount: Int
  }

  @ViewBuilder private var mainContent: some View {
    if let viewModel {
      if viewModel.isLoading && viewModel.sessions.isEmpty {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if visibleSessions(viewModel).isEmpty {
        ContentUnavailableView(
          searchText.isEmpty ? "Nothing imported yet" : "No matches",
          systemImage: "tray",
          description: Text(
            searchText.isEmpty ? emptyStatePrompt : "Try a different search term."))
      } else {
        sessionList(viewModel)
      }
    } else {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func sessionList(_ viewModel: RecentlyAddedViewModel) -> some View {
    List {
      ForEach(visibleSessions(viewModel)) { session in
        Section(header: sessionHeader(session)) {
          ForEach(session.transactions, id: \.id) { transaction in
            RecentlyAddedRow(transaction: transaction)
              .contextMenu {
                Button("Open") { transactionForDetail = transaction }
                Button("Create rule from this\u{2026}") {
                  createRuleFromTransaction = transaction
                }
                Button("Delete", role: .destructive) {
                  Task { await deleteTransaction(transaction) }
                }
              }
          }
        }
      }
    }
    .searchable(text: $searchText, prompt: "Search description, payee, or notes")
  }

  private var reloadKey: ReloadKey {
    ReloadKey(window: window, importedCount: importStore.recentSessions.count)
  }

  /// Platform-specific empty-state copy: macOS users drag files and use
  /// menu items; iOS users share or paste.
  private var emptyStatePrompt: String {
    #if os(macOS)
      return
        "Drop a CSV onto the app, use the Import CSV menu item, "
        + "or paste tabular text to get started."
    #else
      return
        "Use the Share sheet from Files to open a CSV, "
        + "or paste tabular text to get started."
    #endif
  }

  private func sessionHeader(_ session: RecentlyAddedViewModel.SessionGroup) -> some View {
    HStack {
      Text(session.importedAt, format: .dateTime.day().month().year().hour().minute())
        .font(.subheadline)
        .monospacedDigit()
      Spacer()
      if !session.filenames.isEmpty {
        Text(session.filenames.joined(separator: ", "))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      let counts = "\(session.transactions.count) imported"
      let needs =
        session.needsReviewCount > 0 ? " · \(session.needsReviewCount) need review" : ""
      Text(counts + needs)
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .accessibilityElement(children: .combine)
  }

  private func reload() async {
    if viewModel == nil {
      viewModel = RecentlyAddedViewModel(backend: backend)
    }
    await viewModel?.load(window: window)
    await importStore.reloadStagingLists()
  }

  /// Apply `searchText` to the view-model's grouped sessions. Empty query
  /// returns the full list; non-empty filters each session's transactions
  /// (keeping the session shell only if at least one row matches).
  private func visibleSessions(
    _ viewModel: RecentlyAddedViewModel
  ) -> [RecentlyAddedViewModel.SessionGroup] {
    guard !searchText.isEmpty else { return viewModel.sessions }
    let query = searchText.lowercased()
    return
      viewModel.sessions
      .compactMap { group -> RecentlyAddedViewModel.SessionGroup? in
        let matching = group.transactions.filter { transaction in
          matches(transaction, query: query)
        }
        guard !matching.isEmpty else { return nil }
        return RecentlyAddedViewModel.SessionGroup(
          id: group.id,
          importedAt: group.importedAt,
          filenames: group.filenames,
          transactions: matching
        )
      }
  }

  private func matches(_ transaction: Transaction, query: String) -> Bool {
    let haystack: [String] = [
      transaction.payee ?? "",
      transaction.notes ?? "",
      transaction.importOrigin?.rawDescription ?? "",
    ]
    return haystack.contains { $0.lowercased().contains(query) }
  }

  /// Corpus for distinguishing-token extraction: every `rawDescription`
  /// visible in the current window. Empty array means extraction will
  /// fall back to using the single description as-is.
  private func corpusFromViewModel() -> [String] {
    guard let viewModel else { return [] }
    return viewModel.sessions.flatMap { group in
      group.transactions.compactMap { $0.importOrigin?.rawDescription }
    }
  }

  private func deleteTransaction(_ transaction: Transaction) async {
    await transactionStore.delete(id: transaction.id)
    await reload()
  }

  /// Handle a CSV drop (from Finder / Files / another app) onto the view.
  /// Routes via `ImportStore.ingest(source: .droppedFile(forcedAccountId: nil))`
  /// so the matcher picks up if a profile is registered, or the file lands
  /// in Needs Setup otherwise. After ingest, refresh the view-model so new
  /// rows appear.
  private func ingestDroppedURLs(_ urls: [URL]) async {
    for url in urls {
      guard url.pathExtension.lowercased() == "csv" || url.pathExtension.isEmpty else {
        continue
      }
      let didStart = url.startAccessingSecurityScopedResource()
      defer {
        if didStart { url.stopAccessingSecurityScopedResource() }
      }
      guard let data = try? Data(contentsOf: url) else { continue }
      _ = await importStore.ingest(
        data: data, source: .droppedFile(url: url, forcedAccountId: nil))
    }
    await reload()
  }
}

/// Row for one imported transaction. Shows date, description, amount, and a
/// left-edge accent stripe when the row needs review (all legs uncategorised).
private struct RecentlyAddedRow: View {
  let transaction: Transaction

  var body: some View {
    HStack(spacing: 12) {
      Rectangle()
        .fill(needsReview ? Color.orange : Color.clear)
        .frame(width: 3)
        // Purely decorative — the "Needs review" badge carries the
        // screen-reader signal.
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(transaction.payee ?? transaction.importOrigin?.rawDescription ?? "")
          .lineLimit(1)
        Text(transaction.date, format: .dateTime.day().month().year())
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Spacer()
      if let primary = displayAmount {
        InstrumentAmountView(amount: primary, font: .body)
      }
      if needsReview {
        Text("Needs review")
          .font(.caption2)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.orange.opacity(0.15), in: Capsule())
          .foregroundStyle(Color.orange)
          .accessibilityLabel("Needs review")
      }
    }
    .padding(.vertical, 2)
  }

  private var needsReview: Bool {
    transaction.legs.allSatisfy { $0.categoryId == nil }
  }

  /// Pick the first leg (the source/cash leg from the importer) and build
  /// an `InstrumentAmount` so colour coding + per-instrument formatting
  /// come straight from `InstrumentAmountView`. Cross-instrument transfers
  /// intentionally show only the source-side amount here; the detail view
  /// lists both legs.
  private var displayAmount: InstrumentAmount? {
    guard let leg = transaction.legs.first else { return nil }
    return InstrumentAmount(quantity: leg.quantity, instrument: leg.instrument)
  }
}

// `RecentlyAddedNeedsSetupPanel`, `RecentlyAddedPendingRow`, and
// `RecentlyAddedFailedRow` live in `RecentlyAddedNeedsSetupPanel.swift`.

// `RecentlyAddedDetailSheet` and `RecentlyAddedRuleFromSearchSheet` live in
// `RecentlyAddedDetailSheet.swift`.
