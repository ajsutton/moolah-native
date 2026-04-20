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
      NeedsSetupAndFailedPanel()
      if let viewModel {
        if viewModel.isLoading && viewModel.sessions.isEmpty {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.sessions.isEmpty {
          ContentUnavailableView(
            "Nothing imported yet",
            systemImage: "tray",
            description: Text(
              "Drop a CSV onto the app, use the Import CSV menu item, "
                + "or paste tabular text to get started."))
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
  }

  private func reload() async {
    if viewModel == nil {
      viewModel = RecentlyAddedViewModel(backend: backend)
    }
    await viewModel?.load(window: window)
    await importStore.reloadStagingLists()
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
      VStack(alignment: .leading, spacing: 2) {
        Text(transaction.payee ?? transaction.importOrigin?.rawDescription ?? "")
          .lineLimit(1)
        Text(transaction.date, format: .dateTime.day().month().year())
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Spacer()
      Text(amountText)
        .monospacedDigit()
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

  private var amountText: String {
    let total = transaction.legs.reduce(Decimal(0)) { $0 + $1.quantity }
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.maximumFractionDigits = 2
    formatter.minimumFractionDigits = 2
    formatter.currencyCode = transaction.legs.first?.instrument.id ?? "AUD"
    return formatter.string(from: total as NSDecimalNumber) ?? "\(total)"
  }
}

/// Needs Setup / Failed Files panel. Shown above the session list when either
/// list is non-empty; fully hidden when both are empty.
private struct NeedsSetupAndFailedPanel: View {
  @Environment(ImportStore.self) private var importStore

  var body: some View {
    if importStore.pendingSetup.isEmpty && importStore.failedFiles.isEmpty {
      EmptyView()
    } else {
      VStack(alignment: .leading, spacing: 8) {
        if !importStore.pendingSetup.isEmpty {
          Text("Needs Setup").font(.headline)
          ForEach(importStore.pendingSetup) { file in
            PendingRow(file: file)
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
  @Environment(ImportStore.self) private var importStore

  var body: some View {
    HStack {
      Image(systemName: "doc.badge.ellipsis").foregroundStyle(.secondary)
      VStack(alignment: .leading) {
        Text(file.originalFilename).font(.subheadline)
        Text(file.detectedParserIdentifier ?? "Unknown parser")
          .font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Button("Dismiss") {
        Task { await importStore.dismissPending(id: file.id) }
      }
      .buttonStyle(.borderless)
    }
  }
}

private struct FailedRow: View {
  let file: FailedImportFile
  @Environment(ImportStore.self) private var importStore

  var body: some View {
    HStack {
      Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
      VStack(alignment: .leading) {
        Text(file.originalFilename).font(.subheadline)
        Text(file.error)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Spacer()
      Button("Dismiss") {
        Task { await importStore.dismissFailed(id: file.id) }
      }
      .buttonStyle(.borderless)
    }
  }
}
