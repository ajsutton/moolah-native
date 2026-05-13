// Features/Crypto/CryptoWalletAccountView.swift
//
// Detail view for a crypto wallet account.
//
// On macOS the wallet header and the multi-instrument positions panel
// scroll with the transaction rows as a single `topAccessory` slot on
// `TransactionListView`. The leading `Section { topAccessory … }` in
// `TransactionListView+List.swift` is always emitted; when
// `walletHeader` returns `EmptyView` (no chain config) the row
// contributes zero visible pixels.
//
// On iOS the wallet header sits as a sibling of `TransactionListView`
// in a `VStack(spacing: 0)`; this leaf is its own `NavigationStack`
// (provided by `ContentView.detail`'s `.id(selection)` wrap) so the
// header doesn't race with another leaf's `.toolbar` / `.searchable`
// registrations.
import SwiftUI

struct CryptoWalletAccountView: View {
  let account: Account
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore
  let positions: [Position]
  let conversionService: any InstrumentConversionService
  let session: ProfileSession

  var body: some View {
    #if os(macOS)
      MultiInstrumentPositionsTopAccessoryHost(
        positions: positions,
        hostCurrency: account.instrument,
        title: account.name,
        conversionService: conversionService,
        registrationsVersion: registrationsVersion
      ) { panel in
        TransactionListView(
          title: account.name,
          filter: TransactionFilter(accountId: account.id),
          accounts: accounts,
          categories: categories,
          earmarks: earmarks,
          transactionStore: transactionStore,
          topAccessory: { positionsAccessory(panel: panel) }
        )
      }
    #else
      VStack(spacing: 0) {
        walletHeader
        TransactionListView(
          title: account.name,
          filter: TransactionFilter(accountId: account.id),
          accounts: accounts,
          categories: categories,
          earmarks: earmarks,
          transactionStore: transactionStore
        )
        .multiInstrumentPositionsSplit(
          positions: positions,
          hostCurrency: account.instrument,
          title: account.name,
          conversionService: conversionService,
          registrationsVersion: registrationsVersion)
      }
    #endif
  }

  @ViewBuilder private var walletHeader: some View {
    if let chainId = account.chainId,
      let chain = ChainConfig.config(for: chainId),
      let cryptoSyncStore = session.cryptoSyncStore
    {
      WalletAccountHeaderView(
        account: account,
        chain: chain,
        cryptoSyncStore: cryptoSyncStore,
        hasApiKey: session.cryptoTokenStore?.hasAlchemyApiKey ?? false)
    }
  }

  /// Drives a re-fire of the per-row valuator when the user marks a
  /// token as `.spam` from preferences — issue #790. Same value used
  /// by both the macOS top-accessory host and the iOS
  /// `multiInstrumentPositionsSplit` modifier; extracted so both call
  /// sites share one definition.
  private var registrationsVersion: Int {
    session.cryptoTokenStore?.registrationsVersion ?? 0
  }

  #if os(macOS)
    /// macOS top accessory: wallet header followed by the
    /// multi-instrument positions panel. Both scroll as one inside the
    /// transaction list. When `walletHeader` returns `EmptyView` and
    /// `panel == .absent`, the resulting `VStack { EmptyView; EmptyView }`
    /// collapses to zero pixels — same invariant as the always-emit
    /// `Section` row in `TransactionListView+List.swift`.
    @ViewBuilder
    private func positionsAccessory(panel: PositionsPanel) -> some View {
      VStack(spacing: 0) {
        walletHeader
        switch panel {
        case let .panel(input, range):
          PositionsView(input: input, range: range)
        case .loading:
          ProgressView().frame(maxWidth: .infinity).padding()
        case .absent:
          EmptyView()
        }
      }
    }
  #endif
}

// MARK: - Preview

// Minimal preview: the leaf takes a `ProfileSession` as a `let` and
// reaches into `session.cryptoSyncStore` / `session.cryptoTokenStore`
// from `walletHeader`. `ProfileSession.preview()` builds an in-memory
// session whose crypto wiring is `nil`, so `walletHeader` returns
// `EmptyView` and the preview renders the leaf without an actual
// chain header — still useful for verifying the leaf's structural
// shape without launching the app.
#Preview {
  let account = Account(
    id: UUID(),
    name: "Preview Wallet",
    type: .crypto,
    instrument: ChainConfig.ethereum.nativeInstrument,
    valuationMode: .calculatedFromTrades,
    walletAddress: "0x0000000000000000000000000000000000000000",
    chainId: 1)
  // In-memory preview session can't fail in practice: opens an ephemeral
  // GRDB queue with no disk access. A trap here is acceptable in #Preview.
  // swiftlint:disable:next force_try
  let session = try! ProfileSession.preview()
  return NavigationStack {
    CryptoWalletAccountView(
      account: account,
      accounts: Accounts(from: [account]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: session.transactionStore,
      positions: [],
      conversionService: session.backend.conversionService,
      session: session)
  }
  .previewProfileEnvironment(session: session)
}
