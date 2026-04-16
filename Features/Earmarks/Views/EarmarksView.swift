import SwiftData
import SwiftUI

struct EarmarksView: View {
  let earmarkStore: EarmarkStore
  let accounts: Accounts
  let categories: Categories
  let transactionStore: TransactionStore
  let analysisRepository: AnalysisRepository

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
          instrument: earmarkStore.targetInstrument,
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
          onUpdate: { updated in
            Task {
              _ = await earmarkStore.update(updated)
              selectedEarmark = updated
              earmarkToEdit = nil
            }
          }
        )
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
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(earmark.name)
              .font(.headline)
            Spacer()
            InstrumentAmountView(amount: earmark.balance, font: .headline)
          }

          HStack(spacing: 12) {
            Label {
              InstrumentAmountView(amount: earmark.saved, font: .caption)
            } icon: {
              Image(systemName: "arrow.up")
                .foregroundStyle(.green)
            }
            .font(.caption)

            Label {
              InstrumentAmountView(amount: earmark.spent, font: .caption)
            } icon: {
              Image(systemName: "arrow.down")
                .foregroundStyle(.red)
            }
            .font(.caption)
          }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
          "\(earmark.name), balance \(earmark.balance.formatted)"
        )
        .tag(earmark)
        .contextMenu {
          Button("Edit", systemImage: "pencil") {
            earmarkToEdit = earmark
          }
          Divider()
          Button("Hide", systemImage: "eye.slash", role: .destructive) {
            Task {
              var hidden = earmark
              hidden.isHidden = true
              _ = await earmarkStore.update(hidden)
            }
          }
        }
        .swipeActions(edge: .trailing) {
          Button(role: .destructive) {
            Task {
              var hidden = earmark
              hidden.isHidden = true
              _ = await earmarkStore.update(hidden)
            }
          } label: {
            Label("Hide", systemImage: "eye.slash")
          }
        }
        .swipeActions(edge: .leading) {
          Button {
            earmarkToEdit = earmark
          } label: {
            Label("Edit", systemImage: "pencil")
          }
          .tint(.blue)
        }
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
}

#Preview {
  let (backend, _) = PreviewBackend.create()
  let earmarkStore = EarmarkStore(repository: backend.earmarks)
  let transactionStore = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD
  )

  NavigationStack {
    EarmarksView(
      earmarkStore: earmarkStore,
      accounts: Accounts(from: []),
      categories: Categories(from: []),
      transactionStore: transactionStore,
      analysisRepository: backend.analysis
    )
  }
  .task {
    _ = try? await backend.earmarks.create(
      Earmark(
        name: "Holiday Fund",
        savingsGoal: InstrumentAmount(quantity: 5000, instrument: .AUD)))
    _ = try? await backend.earmarks.create(
      Earmark(name: "Emergency Fund"))
    await earmarkStore.load()
  }
}
