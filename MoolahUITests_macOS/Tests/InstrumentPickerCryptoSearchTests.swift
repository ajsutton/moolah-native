import XCTest

/// Happy-path UI test for the crypto-token registration flow:
///   Settings → Crypto → "+" Add Token → search → select → registered.
///
/// Reaches every layer that a store test cannot exercise on its own:
/// the macOS Settings scene's Cmd+, presentation, the TabView tab switch,
/// the `AddTokenSheet`'s `InstrumentPickerSheet` host, the resolve+register
/// overlay/dismissal handshake (`InstrumentPickerStore.isResolving`), and
/// the `CryptoTokenStore.loadRegistrations` reload that surfaces the new
/// registration row. See `guides/UI_TEST_GUIDE.md` §1 for why this earns
/// a UI test slot.
///
/// The `cryptoCatalogPreloaded` seed installs a deterministic catalog with
/// a single Uniswap entry and a stubbed `TokenResolutionClient` so the
/// flow runs without disk or network access — see
/// `App/UITestSeedCryptoOverrides.swift`.
@MainActor
final class InstrumentPickerCryptoSearchTests: MoolahUITestCase {
  /// Registering a crypto token by searching the picker for "uni",
  /// selecting the Uniswap row, and confirming the registration appears
  /// back in the Crypto Settings list.
  func testRegisterCryptoTokenViaPickerSearch() {
    let app = launch(seed: .cryptoCatalogPreloaded)

    app.settings.open()
    app.settings.openCryptoTab()
    app.cryptoSettings.tapAddToken()

    let instrumentId = UITestFixtures.CryptoCatalogPreloaded.instrumentId
    app.addToken.search("uni")
    app.addToken.waitForResult(instrumentId: instrumentId)
    app.addToken.selectResult(instrumentId: instrumentId)
    app.addToken.waitForDismiss()

    app.cryptoSettings.waitForRegistration(instrumentId: instrumentId)
  }
}
