import SwiftData
import SwiftUI

struct EarmarksView: View {
  let earmarkStore: EarmarkStore
  let accounts: Accounts
  let categories: Categories
  let transactionStore: TransactionStore
  let analysisRepository: AnalysisRepository

  @Environment(ProfileSession.self) private var session
  @State private var showCreateSheet = false
  @State private var selectedEarmark: Earmark?
  @State private var earmarkToEdit: Earmark?
  @State private var searchText = ""

  private var showEarmarkInspectorBinding: Binding<Bool> {
    Binding(
      get: { selectedEarmark != nil },
      set: { if !$0 { selectedEarmark = nil } }
    )
  }

  var body: some View {
    listView
      #if os(macOS)
        .inspector(isPresented: showEarmarkInspectorBinding) {
          if let selected = selectedEarmark {
            EarmarkDetailView(
              earmark: selected,
              accounts: accounts,
              categories: categories,
              earmarks: earmarkStore.earmarks,
              transactionStore: transactionStore,
              analysisRepository: analysisRepository
            )
          }
        }
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            if selectedEarmark != nil {
              Button {
                selectedEarmark = nil
              } label: {
                Label("Hide Details", systemImage: "sidebar.trailing")
              }
              .help("Hide Details")
            }
          }
        }
      #else
        .sheet(item: $selectedEarmark) { selected in
          NavigationStack {
            EarmarkDetailView(
              earmark: selected,
              accounts: accounts,
              categories: categories,
              earmarks: earmarkStore.earmarks,
              transactionStore: transactionStore,
              analysisRepository: analysisRepository
            )
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                  selectedEarmark = nil
                }
              }
            }
          }
        }
      #endif
      .sheet(isPresented: $showCreateSheet) {
        CreateEarmarkSheet(
          instrument: session.profile.instrument,
          supportsComplexTransactions: true,
          onCreate: { newEarmark in
            Task {
              _ = await earmarkStore.create(newEarmark)
              showCreateSheet = false
            }
          }
        )
      }
      .sheet(item: $earmarkToEdit) { earmark in
        EditEarmarkSheet(
          earmark: earmark,
          supportsComplexTransactions: true,
          onUpdate: { updated in
            Task {
              _ = await earmarkStore.update(updated)
              selectedEarmark = updated
              earmarkToEdit = nil
            }
          }
        )
      }
      .focusedSceneValue(\.selectedEarmark, $selectedEarmark)
      .onReceive(
        NotificationCenter.default.publisher(for: .requestEarmarkEdit),
        perform: handleEarmarkEditRequest
      )
      .onReceive(
        NotificationCenter.default.publisher(for: .requestEarmarkToggleHidden),
        perform: handleEarmarkToggleHidden
      )
  }

  private func handleEarmarkEditRequest(_ note: Notification) {
    guard let id = note.object as? UUID,
      let earmark = earmarkStore.earmarks.ordered.first(where: { $0.id == id })
    else { return }
    earmarkToEdit = earmark
  }

  private func handleEarmarkToggleHidden(_ note: Notification) {
    guard let id = note.object as? UUID,
      let earmark = earmarkStore.earmarks.ordered.first(where: { $0.id == id })
    else { return }
    Task {
      var updated = earmark
      updated.isHidden.toggle()
      _ = await earmarkStore.update(updated)
    }
  }

  private var filteredEarmarks: [Earmark] {
    if searchText.isEmpty {
      return earmarkStore.earmarks.ordered
    }
    return earmarkStore.earmarks.ordered.filter {
      $0.name.localizedCaseInsensitiveContains(searchText)
    }
  }

  private var listView: some View {
    List(selection: $selectedEarmark) {
      ForEach(filteredEarmarks) { earmark in
        earmarkRow(earmark)
      }
    }
    #if os(macOS)
      .listStyle(.inset)
    #else
      .listStyle(.plain)
    #endif
    .profileNavigationTitle("Earmarks")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          showCreateSheet = true
        } label: {
          Label("Add Earmark", systemImage: "plus")
        }
      }
    }
    .task {
      await earmarkStore.load()
    }
    .refreshable {
      await earmarkStore.load()
    }
    .searchable(text: $searchText, prompt: "Search earmarks")
    .overlay {
      if earmarkStore.isLoading && earmarkStore.earmarks.ordered.isEmpty {
        ProgressView()
      } else if !earmarkStore.isLoading && earmarkStore.earmarks.ordered.isEmpty {
        ContentUnavailableView(
          "No Earmarks",
          systemImage: "bookmark.fill",
          description: Text("Create an earmark to start tracking savings goals.")
        )
      }
    }
  }

  private func earmarkRow(_ earmark: Earmark) -> some View {
    earmarkRowContent(earmark)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        "\(earmark.name), balance \(earmarkStore.convertedBalance(for: earmark.id)?.formatted ?? "loading")"
      )
      .tag(earmark)
      .contextMenu { rowContextMenu(for: earmark) }
      .swipeActions(edge: .trailing) {
        Button {
          Task { await toggleHidden(earmark) }
        } label: {
          Label(
            earmark.isHidden ? "Show Earmark" : "Hide Earmark",
            systemImage: earmark.isHidden ? "eye" : "eye.slash")
        }
        .tint(earmark.isHidden ? .green : .orange)
      }
      .swipeActions(edge: .leading) {
        Button {
          earmarkToEdit = earmark
        } label: {
          Label("Edit Earmark", systemImage: "pencil")
        }
        .tint(.blue)
      }
  }

  private func earmarkRowContent(_ earmark: Earmark) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(earmark.name).font(.headline)
        Spacer()
        InstrumentAmountView(
          amount: earmarkStore.convertedBalance(for: earmark.id)
            ?? .zero(instrument: earmark.instrument), font: .headline)
      }
      HStack(spacing: 12) {
        Label {
          InstrumentAmountView(
            amount: earmarkStore.convertedSaved(for: earmark.id)
              ?? .zero(instrument: earmark.instrument), font: .caption)
        } icon: {
          Image(systemName: "arrow.up").foregroundStyle(.green)
        }
        .font(.caption)
        Label {
          InstrumentAmountView(
            amount: earmarkStore.convertedSpent(for: earmark.id)
              ?? .zero(instrument: earmark.instrument), font: .caption)
        } icon: {
          Image(systemName: "arrow.down").foregroundStyle(.red)
        }
        .font(.caption)
      }
    }
  }

  @ViewBuilder
  private func rowContextMenu(for earmark: Earmark) -> some View {
    Button("Edit Earmark\u{2026}", systemImage: "pencil") {
      earmarkToEdit = earmark
    }
    Divider()
    Button(
      earmark.isHidden ? "Show Earmark" : "Hide Earmark",
      systemImage: earmark.isHidden ? "eye" : "eye.slash"
    ) {
      Task { await toggleHidden(earmark) }
    }
  }

  private func toggleHidden(_ earmark: Earmark) async {
    var updated = earmark
    updated.isHidden.toggle()
    _ = await earmarkStore.update(updated)
  }
}

#Preview {
  let (backend, _) = PreviewBackend.create()
  let earmarkStore = EarmarkStore(
    repository: backend.earmarks,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  let transactionStore = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD
  )
  let session = ProfileSession(profile: Profile(label: "Preview"))

  return NavigationStack {
    EarmarksView(
      earmarkStore: earmarkStore,
      accounts: Accounts(from: []),
      categories: Categories(from: []),
      transactionStore: transactionStore,
      analysisRepository: backend.analysis
    )
    .environment(session)
  }
  .task { await seedEarmarksPreview(backend: backend, earmarkStore: earmarkStore) }
}

@MainActor
private func seedEarmarksPreview(backend: CloudKitBackend, earmarkStore: EarmarkStore) async {
  _ = try? await backend.earmarks.create(
    Earmark(
      name: "Holiday Fund",
      instrument: .AUD,
      savingsGoal: InstrumentAmount(quantity: 5000, instrument: .AUD)))
  _ = try? await backend.earmarks.create(Earmark(name: "Emergency Fund", instrument: .AUD))
  await earmarkStore.load()
}
