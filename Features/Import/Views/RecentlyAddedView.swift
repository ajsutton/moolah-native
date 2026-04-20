import SwiftUI

/// Recently Added — landing page for CSV imports. Shows the Needs Setup /
/// Failed Files panel at the top and a session-grouped list of recently
/// imported transactions below. The time window picker is in the toolbar.
struct RecentlyAddedView: View {
  let backend: any BackendProvider
  @Environment(ImportStore.self) private var importStore
  @State private var viewModel: RecentlyAddedViewModel?
  @State private var window: RecentlyAddedViewModel.Window = .last24Hours

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      NeedsSetupAndFailedPanel(backend: backend, staging: importStore.staging)
      if let viewModel {
        if viewModel.isLoading && viewModel.sessions.isEmpty {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.sessions.isEmpty {
          ContentUnavailableView(
            "Nothing imported yet",
            systemImage: "tray",
            description: Text(emptyStatePrompt))
        } else {
          List {
            ForEach(viewModel.sessions) { session in
              Section(header: sessionHeader(session)) {
                ForEach(session.transactions, id: \.id) { tx in
                  RecentlyAddedRow(transaction: tx)
                }
              }
            }
          }
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
    }
    // .task(id: window) fires on first appearance and re-fires (auto-cancelling
    // any in-flight load) whenever `window` changes.
    .task(id: window) { await reload() }
    // After a successful ingest (including `finishSetup` completing a
    // Needs Setup file) `ImportStore.recentSessions` grows. Use that as
    // the signal to re-query the backend so the new transactions appear
    // in the session list without the user having to switch the window.
    .onChange(of: importStore.recentSessions.count) { _, _ in
      Task { await reload() }
    }
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
        data: data,
        source: .droppedFile(url: url, forcedAccountId: nil))
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
      Button("Dismiss") {
        Task { await importStore.dismissFailed(id: file.id) }
      }
      .buttonStyle(.borderless)
    }
  }
}
