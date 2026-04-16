import SwiftUI

enum SidebarSelection: Hashable {
  case account(UUID)
  case earmark(UUID)
  case allTransactions
  case upcomingTransactions
  case categories
  case reports
  case analysis
}

struct SidebarView: View {
  @Environment(AccountStore.self) private var accountStore
  @Environment(EarmarkStore.self) private var earmarkStore
  @Environment(ProfileSession.self) private var session
  @Binding var selection: SidebarSelection?
  @State private var showCreateEarmarkSheet = false
  @State private var showCreateAccountSheet = false
  @State private var accountToEdit: Account?
  @AppStorage("showHiddenAccounts") private var showHidden = false
  #if os(iOS)
    @State private var editMode: EditMode = .inactive
  #endif

  var body: some View {
    List(selection: $selection) {
      Section {
        ForEach(accountStore.currentAccounts) { account in
          NavigationLink(value: SidebarSelection.account(account.id)) {
            SidebarRowView(
              icon: account.sidebarIcon, name: account.name,
              amount: accountStore.displayBalance(for: account.id),
              isSelected: selection == .account(account.id))
          }
          .contextMenu {
            Button("Edit Account", systemImage: "pencil") {
              accountToEdit = account
            }
            Button("View Transactions", systemImage: "list.bullet") {
              selection = .account(account.id)
            }
          }
        }
        .onMove { source, destination in
          Task { await reorderCurrentAccounts(from: source, to: destination) }
        }

        totalRow(label: "Current Total", value: accountStore.convertedCurrentTotal)
      } header: {
        HStack {
          Text("Current Accounts")
          Spacer()
          #if os(iOS)
            Button {
              showCreateAccountSheet = true
            } label: {
              Image(systemName: "plus")
                .font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add account")
          #endif
        }
      }

      if !earmarkStore.visibleEarmarks.isEmpty {
        Section {
          ForEach(earmarkStore.visibleEarmarks) { earmark in
            NavigationLink(value: SidebarSelection.earmark(earmark.id)) {
              SidebarRowView(
                icon: "bookmark.fill", name: earmark.name,
                amount: earmarkStore.convertedBalance(for: earmark.id)
                  ?? .zero(instrument: earmark.instrument),
                isSelected: selection == .earmark(earmark.id))
            }
          }
          .onMove { source, destination in
            Task { await earmarkStore.reorderEarmarks(from: source, to: destination) }
          }

          totalRow(label: "Earmarked Total", value: earmarkStore.convertedTotalBalance)
        } header: {
          HStack {
            Text("Earmarks")
            Spacer()
            #if os(iOS)
              Button {
                showCreateEarmarkSheet = true
              } label: {
                Image(systemName: "plus")
                  .font(.caption)
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Add earmark")
            #endif
          }
        }
      }

      Section("Investments") {
        ForEach(accountStore.investmentAccounts) { account in
          NavigationLink(value: SidebarSelection.account(account.id)) {
            SidebarRowView(
              icon: account.sidebarIcon, name: account.name,
              amount: accountStore.displayBalance(for: account.id),
              isSelected: selection == .account(account.id))
          }
          .contextMenu {
            Button("Edit Account", systemImage: "pencil") {
              accountToEdit = account
            }
            Button("View Transactions", systemImage: "list.bullet") {
              selection = .account(account.id)
            }
          }
        }
        .onMove { source, destination in
          Task { await reorderInvestmentAccounts(from: source, to: destination) }
        }

        totalRow(label: "Investment Total", value: accountStore.convertedInvestmentTotal)
      }

      Section {
        if let currentTotal = accountStore.convertedCurrentTotal,
          let earmarkedTotal = earmarkStore.convertedTotalBalance,
          earmarkedTotal.isPositive
        {
          LabeledContent("Available Funds") {
            InstrumentAmountView(amount: currentTotal - earmarkedTotal)
          }
          .font(.headline)
          .accessibilityLabel(
            "Available Funds: \((currentTotal - earmarkedTotal).formatted)"
          )
        }

        if let netWorth = accountStore.convertedNetWorth {
          LabeledContent("Net Worth") {
            InstrumentAmountView(amount: netWorth)
          }
          .font(.headline)
          .bold()
          .accessibilityLabel(
            "Net Worth: \(netWorth.formatted)"
          )
        }
      }

      Section {
        NavigationLink(value: SidebarSelection.analysis) {
          Label("Analysis", systemImage: "chart.bar.xaxis")
        }

        NavigationLink(value: SidebarSelection.reports) {
          Label("Reports", systemImage: "chart.bar.fill")
        }

        NavigationLink(value: SidebarSelection.categories) {
          Label("Categories", systemImage: "tag")
        }

        NavigationLink(value: SidebarSelection.upcomingTransactions) {
          Label("Upcoming", systemImage: "calendar")
        }

        NavigationLink(value: SidebarSelection.allTransactions) {
          Label("All Transactions", systemImage: "list.bullet")
        }

        #if os(iOS)
          Toggle(isOn: $showHidden) {
            Label("Show Hidden", systemImage: "eye.slash")
          }
        #endif
      }
    }
    .listStyle(.sidebar)
    .navigationTitle("")
    .focusedSceneValue(\.showHiddenAccounts, $showHidden)
    .onChange(of: showHidden) { _, newValue in
      accountStore.showHidden = newValue
      earmarkStore.showHidden = newValue
    }
    .onAppear {
      accountStore.showHidden = showHidden
      earmarkStore.showHidden = showHidden
    }
    #if os(iOS)
      .environment(\.editMode, $editMode)
    #endif
    .refreshable {
      async let a: Void = accountStore.load()
      async let e: Void = earmarkStore.load()
      _ = await (a, e)
    }
    #if os(macOS)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            showCreateAccountSheet = true
          } label: {
            Label("New Account", systemImage: "plus")
          }
          .help("Create new account")
        }
      }
    #endif
    .focusedSceneValue(\.newEarmarkAction) {
      showCreateEarmarkSheet = true
    }
    .sheet(isPresented: $showCreateEarmarkSheet) {
      CreateEarmarkSheet(
        instrument: earmarkStore.targetInstrument,
        onCreate: { newEarmark in
          Task {
            _ = await earmarkStore.create(newEarmark)
            showCreateEarmarkSheet = false
          }
        }
      )
    }
    .sheet(isPresented: $showCreateAccountSheet) {
      CreateAccountView(
        instrument: accountStore.currentTotal.instrument, accountStore: accountStore,
        supportsComplexTransactions: session.profile.supportsComplexTransactions)
    }
    .sheet(item: $accountToEdit) { account in
      EditAccountView(
        account: account, accountStore: accountStore,
        supportsComplexTransactions: session.profile.supportsComplexTransactions)
    }
  }

  private func totalRow(label: String, value: InstrumentAmount?) -> some View {
    LabeledContent(label) {
      if let value {
        InstrumentAmountView(amount: value, colorOverride: .secondary)
      } else {
        ProgressView()
          .controlSize(.small)
      }
    }
    .foregroundStyle(.secondary)
    .font(.callout)
  }

  private func reorderCurrentAccounts(from source: IndexSet, to destination: Int) async {
    var accounts = accountStore.currentAccounts
    accounts.move(fromOffsets: source, toOffset: destination)
    await accountStore.reorderAccounts(accounts)
  }

  private func reorderInvestmentAccounts(from source: IndexSet, to destination: Int) async {
    var accounts = accountStore.investmentAccounts
    accounts.move(fromOffsets: source, toOffset: destination)
    await accountStore.reorderAccounts(
      accounts, positionOffset: accountStore.currentAccounts.count)
  }
}

#Preview {
  let (backend, _) = PreviewBackend.create()
  let accountStore = AccountStore(repository: backend.accounts)
  let earmarkStore = EarmarkStore(repository: backend.earmarks)
  let session = ProfileSession(profile: Profile(label: "Preview", backendType: .moolah))

  NavigationSplitView {
    SidebarView(selection: .constant(nil))
      .environment(accountStore)
      .environment(earmarkStore)
      .environment(session)
      .task {
        // Add some preview data
        _ = try? await backend.accounts.create(
          Account(
            name: "Bank", type: .bank),
          openingBalance: InstrumentAmount(quantity: 1000, instrument: .AUD))
        _ = try? await backend.accounts.create(
          Account(
            name: "Asset", type: .asset),
          openingBalance: InstrumentAmount(quantity: 5000, instrument: .AUD))
        _ = try? await backend.earmarks.create(
          Earmark(name: "Holiday Fund"))

        await accountStore.load()
        await earmarkStore.load()
      }
  } detail: {
    Text("Detail")
  }
}
