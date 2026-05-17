import Testing

@testable import Moolah

/// Per-type seam for `SyncedAccountHeaderView`. The presentation is the
/// only place account-type branching is allowed for synced-account UI:
/// these tests pin the identifier, external-open target, identifier
/// selectability, secondary line and missing-credential hint for crypto,
/// exchange and non-syncable accounts.
@Suite("SyncableAccountPresentation")
struct SyncableAccountPresentationTests {
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)

  @Test
  func cryptoShowsTruncatedAddressAndExplorer() {
    let addr = "0x" + String(repeating: "a", count: 40)
    let account = Account(
      name: "W", type: .crypto, instrument: eth,
      walletAddress: addr, chainId: 1)
    let presentation = SyncableAccountPresentation(account: account, hasCredential: true)
    #expect(presentation.identifier.hasPrefix("0xaa"))
    #expect(presentation.identifier.contains("…"))
    #expect(presentation.externalActionTitle == "Open in block explorer")
    #expect(presentation.externalURL?.absoluteString.contains(addr) == true)
    #expect(presentation.missingCredentialHint == nil)
    #expect(presentation.secondaryIdentifier == "Ethereum")
  }

  @Test
  func exchangeShowsProviderWebsiteAndIdentifier() {
    let account = Account(
      name: "C", type: .exchange, instrument: .AUD,
      exchangeProvider: .coinstash)
    let presentation = SyncableAccountPresentation(account: account, hasCredential: false)
    #expect(presentation.identifier == "Coinstash")
    #expect(presentation.externalActionTitle == "Open Coinstash")
    #expect(presentation.externalURL?.host?.contains("coinstash") == true)
    #expect(presentation.secondaryIdentifier == nil)
    #expect(presentation.missingCredentialHint != nil)
  }

  @Test
  func nonSyncableHasNoExternalTargetOrTitle() {
    let account = Account(name: "B", type: .bank, instrument: .AUD)
    let presentation = SyncableAccountPresentation(account: account, hasCredential: true)
    #expect(presentation.externalURL == nil)
    #expect(presentation.externalActionTitle == nil)
  }

  @Test
  func exchangeWithNilProviderHasNoDanglingTitle() {
    let account = Account(
      name: "X", type: .exchange, instrument: .AUD,
      exchangeProvider: nil)
    let presentation = SyncableAccountPresentation(account: account, hasCredential: false)
    #expect(presentation.externalURL == nil)
    #expect(presentation.externalActionTitle == nil)
  }
}
