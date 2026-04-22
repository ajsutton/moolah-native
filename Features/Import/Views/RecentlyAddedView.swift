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
      NeedsSetupAndFailedPanel(backend: backend, staging: importStore.staging)
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
          List {
            ForEach(visibleSessions(viewModel)) { session in
              Section(header: sessionHeader(session)) {
                ForEach(session.transactions, id: \.id) { tx in
                  RecentlyAddedRow(transaction: tx)
                    .contextMenu {
                      Button("Open") { transactionForDetail = tx }
                      Button("Create rule from this\u{2026}") {
                        createRuleFromTransaction = tx
                      }
                      Button("Delete", role: .destructive) {
                        Task { await deleteTransaction(tx) }
                      }
                    }
                }
              }
            }
          }
          .searchable(text: $searchText, prompt: "Search description, payee, or notes")
        }
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .navigationTitle("Recently Added")
    .dropDestination(for: URL.self) { urls, _ in
      Task { await ingestDroppedURLs(urls) }
      return !urls.isEmpty
    }
    .toolbar {
      ToolbarItem(placement: .automatic) {
        Picker("Time window", selection: $window) {
          ForEach(RecentlyAddedViewModel.Window.allCases) { w in
            Text(w.label).tag(w)
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
    .sheet(item: $createRuleFromTransaction) { tx in
      CreateRuleFromTransactionSheet(
        transaction: tx,
        corpus: corpusFromViewModel())
    }
    .sheet(isPresented: $showingCreateRuleFromSearch) {
      RuleFromSearchSheet(query: searchText)
    }
    .sheet(item: $transactionForDetail) { tx in
      TransactionDetailSheet(transaction: tx)
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
        let matching = group.transactions.filter { tx in
          matches(tx, query: query)
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

  private func matches(_ tx: Transaction, query: String) -> Bool {
    let haystack: [String] = [
      tx.payee ?? "",
      tx.notes ?? "",
      tx.importOrigin?.rawDescription ?? "",
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

  private func deleteTransaction(_ tx: Transaction) async {
    await transactionStore.delete(id: tx.id)
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

/// Needs Setup / Failed Files panel. Shown above the session list when either
/// list is non-empty; fully hidden when both are empty.
private struct NeedsSetupAndFailedPanel: View {
  let backend: any BackendProvider
  let staging: ImportStagingStore
  @Environment(ImportStore.self) private var importStore

  var body: some View {
    if importStore.pendingSetup.isEmpty && importStore.failedFiles.isEmpty {
      EmptyView()
    } else {
      VStack(alignment: .leading, spacing: 8) {
        if !importStore.pendingSetup.isEmpty {
          Text("Needs Setup").font(.headline)
          ForEach(importStore.pendingSetup) { file in
            PendingRow(file: file, backend: backend, staging: staging)
          }
        }
        if !importStore.failedFiles.isEmpty {
          Text("Failed Files").font(.headline)
          ForEach(importStore.failedFiles) { file in
            FailedRow(file: file)
          }
        }
      }
      .padding()
      .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
      .padding(.horizontal)
      .padding(.top)
    }
  }
}

private struct PendingRow: View {
  let file: PendingSetupFile
  let backend: any BackendProvider
  let staging: ImportStagingStore
  @Environment(ImportStore.self) private var importStore
  @State private var setupStore: CSVImportSetupStore?

  var body: some View {
    HStack {
      Image(systemName: "doc.badge.ellipsis")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading) {
        Text(file.originalFilename).font(.subheadline)
        Text(file.detectedParserIdentifier ?? "Unknown parser")
          .font(.caption).foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(file.originalFilename), needs setup")
      Spacer()
      Button("Set up\u{2026}") {
        // Build the store lazily on first open so re-renders of the parent
        // don't wipe user-entered form state. Held in @State for stability
        // across sheet dismiss/show cycles.
        setupStore = CSVImportSetupStore(
          pending: file, backend: backend,
          importStore: importStore, staging: staging)
      }
      .buttonStyle(.borderless)
      Button("Dismiss") {
        Task { await importStore.dismissPending(id: file.id) }
      }
      .buttonStyle(.borderless)
    }
    .sheet(
      isPresented: Binding(
        get: { setupStore != nil },
        set: { if !$0 { setupStore = nil } })
    ) {
      if let setupStore {
        CSVImportSetupView(store: setupStore)
      }
    }
  }
}

private struct FailedRow: View {
  let file: FailedImportFile
  @Environment(ImportStore.self) private var importStore

  var body: some View {
    HStack {
      Image(systemName: "exclamationmark.triangle")
        .foregroundStyle(.red)
        .accessibilityHidden(true)
      VStack(alignment: .leading) {
        Text(file.originalFilename).font(.subheadline)
        Text(file.error)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(file.originalFilename) failed: \(file.error)")
      Spacer()
      // Always available — we re-read the staged bytes, not the
      // original URL, so retries work even for paste/folder-watch files
      // whose source URLs are gone.
      Button("Retry") {
        Task { await importStore.retryFailed(id: file.id) }
      }
      .buttonStyle(.borderless)
      Button("Dismiss") {
        Task { await importStore.dismissFailed(id: file.id) }
      }
      .buttonStyle(.borderless)
    }
  }
}

/// Thin read-only transaction summary for the Recently Added context-menu
/// "Open" action. Shows date, amount, legs, and the raw import origin so
/// the user can verify what was imported without launching the full
/// editor. For edits, they navigate to the transaction list and open it
/// there.
private struct TransactionDetailSheet: View {
  let transaction: Transaction
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section("Transaction") {
          LabeledContent("Date") {
            Text(transaction.date, format: .dateTime.day().month().year())
              .monospacedDigit()
          }
          if let payee = transaction.payee, !payee.isEmpty {
            LabeledContent("Payee", value: payee)
          }
          if let notes = transaction.notes, !notes.isEmpty {
            LabeledContent("Notes", value: notes)
          }
        }
        Section("Legs") {
          ForEach(Array(transaction.legs.enumerated()), id: \.offset) { _, leg in
            HStack {
              Text(leg.type.rawValue.capitalized)
                .foregroundStyle(.secondary)
              Spacer()
              InstrumentAmountView(
                amount: InstrumentAmount(
                  quantity: leg.quantity, instrument: leg.instrument),
                font: .body)
            }
          }
        }
        if let origin = transaction.importOrigin {
          Section("Import origin") {
            LabeledContent("Source", value: origin.sourceFilename ?? origin.parserIdentifier)
            LabeledContent("Raw description", value: origin.rawDescription)
            if let ref = origin.bankReference, !ref.isEmpty {
              LabeledContent("Bank reference", value: ref)
            }
            LabeledContent("Imported") {
              Text(origin.importedAt, format: .dateTime.day().month().year().hour().minute())
                .monospacedDigit()
            }
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Transaction")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
      #endif
    }
  }
}

/// Bridges a Recently Added search query into a pre-filled rule editor.
/// The query is tokenised on whitespace; each token becomes a term in a
/// single `descriptionContains` condition.
private struct RuleFromSearchSheet: View {
  let query: String
  @Environment(ImportRuleStore.self) private var ruleStore

  var body: some View {
    RuleEditorView(
      initialRule: ImportRule(
        name: "Rule from \"\(query.prefix(20))\"",
        position: ruleStore.rules.count,
        conditions: [.descriptionContains(tokens)],
        actions: []),
      onSave: { rule in
        Task { await ruleStore.create(rule) }
      })
  }

  private var tokens: [String] {
    query
      .split(separator: " ", omittingEmptySubsequences: true)
      .map { String($0) }
  }
}
