// swiftlint:disable multiline_arguments

import SwiftUI

enum SidebarSelection: Hashable {
  case account(UUID)
  case earmark(UUID)
  case recentlyAdded
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
  @Environment(ImportStore.self) private var importStore
  @Binding var selection: SidebarSelection?
  @State private var showCreateEarmarkSheet = false
  @State private var showCreateAccountSheet = false
  @State private var accountToEdit: Account?
  @AppStorage("showHiddenAccounts") private var showHidden = false

  #if os(iOS)
    @State private var editMode: EditMode = .inactive
  #endif

  private var selectedAccountBinding: Binding<Account?> {
    Binding(
      get: {
        guard case .account(let id) = selection else { return nil }
        return accountStore.accounts.by(id: id)
      },
      set: { newAccount in
        selection = newAccount.map { .account($0.id) }
      }
    )
  }

  var body: some View {
    List(selection: $selection) {
      currentAccountsSection
      earmarksSection
      investmentsSection
      totalsSection
      navigationSection
    }
    .listStyle(.sidebar)
    .navigationTitle("")
    .focusedSceneValue(\.showHiddenAccounts, $showHidden)
    .focusedSceneValue(\.sidebarSelection, $selection)
    .focusedSceneValue(\.selectedAccount, selectedAccountBinding)
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
      async let accountsLoad: Void = accountStore.load()
      async let earmarksLoad: Void = earmarkStore.load()
      _ = await (accountsLoad, earmarksLoad)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      SyncProgressFooter()
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
          .accessibilityIdentifier(UITestIdentifiers.Sidebar.newAccountButton)
        }
      }
    #endif
    .focusedSceneValue(\.newEarmarkAction) {
      showCreateEarmarkSheet = true
    }
    .focusedSceneValue(\.newAccountAction) {
      showCreateAccountSheet = true
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
    .sheet(isPresented: $showCreateAccountSheet) {
      CreateAccountView(
        instrument: session.profile.instrument, accountStore: accountStore,
        supportsComplexTransactions: session.profile.supportsComplexTransactions)
    }
    .sheet(item: $accountToEdit) { account in
      EditAccountView(
        account: account, accountStore: accountStore,
        supportsComplexTransactions: session.profile.supportsComplexTransactions)
    }
    .onReceive(
      NotificationCenter.default.publisher(for: .requestAccountEdit),
      perform: handleAccountEditRequest
    )
  }

  private func handleAccountEditRequest(_ note: Notification) {
    guard let id = note.object as? UUID,
      let account = accountStore.accounts.by(id: id)
    else { return }
    accountToEdit = account
  }

  private var currentAccountsSection: some View {
    Section {
      ForEach(accountStore.currentAccounts) { account in
        NavigationLink(value: SidebarSelection.account(account.id)) {
          AccountSidebarRow(account: account, isSelected: selection == .account(account.id))
        }
        .dropDestination(for: URL.self) { urls, _ in
          Task { await ingestDroppedURLs(urls, forcedAccountId: account.id) }
          return !urls.isEmpty
        }
        .accessibilityIdentifier(UITestIdentifiers.Sidebar.account(account.id))
        .contextMenu { accountContextMenu(for: account) }
      }
      .onMove { source, destination in
        Task { await reorderCurrentAccounts(from: source, to: destination) }
      }
      totalRow(label: "Current Total", value: accountStore.convertedCurrentTotal)
    } header: {
      sectionHeader(title: "Current Accounts", addAction: addAccountAction)
    }
  }

  @ViewBuilder private var earmarksSection: some View {
    if !earmarkStore.visibleEarmarks.isEmpty {
      Section {
        ForEach(earmarkStore.visibleEarmarks) { earmark in
          NavigationLink(value: SidebarSelection.earmark(earmark.id)) {
            SidebarRowView(
              icon: "bookmark.fill", name: earmark.name,
              amount: earmarkStore.convertedBalance(for: earmark.id),
              isSelected: selection == .earmark(earmark.id))
          }
        }
        .onMove { source, destination in
          Task { await earmarkStore.reorderEarmarks(from: source, to: destination) }
        }
        totalRow(label: "Earmarked Total", value: earmarkStore.convertedTotalBalance)
      } header: {
        sectionHeader(title: "Earmarks", addAction: addEarmarkAction)
      }
    }
  }

  private var investmentsSection: some View {
    Section("Investments") {
      ForEach(accountStore.investmentAccounts) { account in
        NavigationLink(value: SidebarSelection.account(account.id)) {
          AccountSidebarRow(account: account, isSelected: selection == .account(account.id))
        }
        .accessibilityIdentifier(UITestIdentifiers.Sidebar.account(account.id))
        .contextMenu { accountContextMenu(for: account) }
      }
      .onMove { source, destination in
        Task { await reorderInvestmentAccounts(from: source, to: destination) }
      }
      totalRow(label: "Investment Total", value: accountStore.convertedInvestmentTotal)
    }
  }

  @ViewBuilder private var totalsSection: some View {
    Section {
      if let currentTotal = accountStore.convertedCurrentTotal,
        let earmarkedTotal = earmarkStore.convertedTotalBalance,
        earmarkedTotal.isPositive
      {
        LabeledContent("Available Funds") {
          InstrumentAmountView(amount: currentTotal - earmarkedTotal)
        }
        .font(.headline)
        .accessibilityLabel("Available Funds: \((currentTotal - earmarkedTotal).formatted)")
      }
      if let netWorth = accountStore.convertedNetWorth {
        LabeledContent("Net Worth") {
          InstrumentAmountView(amount: netWorth)
        }
        .font(.headline)
        .bold()
        .accessibilityLabel("Net Worth: \(netWorth.formatted)")
      }
    }
  }

  @ViewBuilder private var navigationSection: some View {
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
      NavigationLink(value: SidebarSelection.recentlyAdded) {
        recentlyAddedLabel
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

  private func addAccountAction() { showCreateAccountSheet = true }
  private func addEarmarkAction() { showCreateEarmarkSheet = true }

  private func reorderCurrentAccounts(from source: IndexSet, to destination: Int) async {
    var accounts = accountStore.currentAccounts
    accounts.move(fromOffsets: source, toOffset: destination)
    await accountStore.reorderAccounts(accounts)
  }

  /// Dropped CSV onto a sidebar account row: force the import onto that
  /// account, bypassing profile matching. A profile is created on success.
  private func ingestDroppedURLs(_ urls: [URL], forcedAccountId: UUID) async {
    for url in urls
    where url.pathExtension.lowercased() == "csv"
      || url.pathExtension.isEmpty
    {
      let didStart = url.startAccessingSecurityScopedResource()
      defer {
        if didStart { url.stopAccessingSecurityScopedResource() }
      }
      guard let data = try? Data(contentsOf: url) else { continue }
      _ = await importStore.ingest(
        data: data,
        source: .droppedFile(url: url, forcedAccountId: forcedAccountId))
    }
  }

  private func reorderInvestmentAccounts(from source: IndexSet, to destination: Int) async {
    var accounts = accountStore.investmentAccounts
    accounts.move(fromOffsets: source, toOffset: destination)
    await accountStore.reorderAccounts(
      accounts, positionOffset: accountStore.currentAccounts.count)
  }
}

extension SidebarView {
  private var recentlyAddedLabel: some View {
    HStack {
      Label("Recently Added", systemImage: "tray.full")
      Spacer()
      if importStore.unreviewedBadgeCount > 0 {
        Text("\(importStore.unreviewedBadgeCount)")
          .font(.caption)
          .monospacedDigit()
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(.tint, in: Capsule())
          .foregroundStyle(.white)
          .accessibilityLabel(
            "\(importStore.unreviewedBadgeCount) recently imported need review")
      }
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

  @ViewBuilder
  private func accountContextMenu(for account: Account) -> some View {
    Button("Edit Account\u{2026}", systemImage: "pencil") {
      accountToEdit = account
    }
    Button("View Transactions", systemImage: "list.bullet") {
      selection = .account(account.id)
    }
  }

  @ViewBuilder
  private func sectionHeader(title: String, addAction: @escaping () -> Void) -> some View {
    HStack {
      Text(title)
      Spacer()
      #if os(iOS)
        Button(action: addAction) {
          Image(systemName: "plus").font(.caption)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add \(title.lowercased())")
      #endif
    }
  }
}

@MainActor
private func seedSidebarPreview(
  backend: CloudKitBackend,
  accountStore: AccountStore,
  earmarkStore: EarmarkStore
) async {
  _ = try? await backend.accounts.create(
    Account(name: "Bank", type: .bank, instrument: .AUD),
    openingBalance: InstrumentAmount(quantity: 1000, instrument: .AUD))
  _ = try? await backend.accounts.create(
    Account(name: "Asset", type: .asset, instrument: .AUD),
    openingBalance: InstrumentAmount(quantity: 5000, instrument: .AUD))
  _ = try? await backend.earmarks.create(Earmark(name: "Holiday Fund", instrument: .AUD))
  await accountStore.load()
  await earmarkStore.load()
}

#Preview {
  let (backend, _) = PreviewBackend.create()
  let accountStore = AccountStore(
    repository: backend.accounts,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  let earmarkStore = EarmarkStore(
    repository: backend.earmarks,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  let session = ProfileSession(profile: Profile(label: "Preview", backendType: .moolah))

  return NavigationSplitView {
    SidebarView(selection: .constant(nil))
      .environment(accountStore)
      .environment(earmarkStore)
      .environment(session)
      .task {
        await seedSidebarPreview(
          backend: backend, accountStore: accountStore, earmarkStore: earmarkStore)
      }
  } detail: {
    Text("Detail")
  }
}
