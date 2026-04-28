import AppKit
import XCTest

/// Failure-artefact collection for `MoolahUITestCase`. Split out so the
/// base class itself stays close to the public driver primitives that
/// individual tests use; the reader doesn't need to scroll past the
/// fixture-formatting helpers to find them.
///
/// `collectFailureArtefacts(for:succeeded:)` is the only entry point —
/// invoked from the base class's `tearDown` — every other helper here
/// is private to this file.
extension MoolahUITestCase {

  // MARK: - Driver-callable: in-flight failure snapshot

  /// Counter so each `captureFailureSnapshot` call writes to a distinct
  /// filename (`failure-1-<reason>.png/.txt`, `failure-2-...`). Reset
  /// implicitly per test by `setUp` reassigning the case instance.
  private static let failureSnapshotCounters = NSMapTable<XCTestCase, NSNumber>
    .weakToStrongObjects()

  /// Captures an immediate screenshot + accessibility-tree dump at the
  /// point a driver action determined it could not proceed (e.g.
  /// `tap()` clicked at the field's coordinates but no element ever
  /// reported `hasKeyboardFocus`).
  ///
  /// Drivers call this **before** `XCTFail` so the snapshot reflects the
  /// pixels that were on screen at the failure point — by the time the
  /// `tearDown` snapshot fires, dropdowns may have dismissed, the form
  /// may have scrolled, and the screen no longer reflects what the user
  /// would have seen at the moment the action gave up.
  ///
  /// Files land under the test's failure-artefact directory using a
  /// per-test counter so multiple captures in the same test do not
  /// overwrite each other.
  func captureFailureSnapshot(reason: String) {
    guard let app = lastApp else { return }
    let dir = artefactDirectory(for: name)
    do {
      try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true)
    } catch {
      add(XCTAttachment(string: "Failed to create snapshot dir: \(error)"))
      return
    }
    print("[MoolahUITestCase] ARTEFACT_DIR \(dir.path)")
    let counter = nextSnapshotCounter()
    let safeReason =
      reason
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: " ", with: "_")
    let basename = "failure-\(counter)-\(safeReason)"
    // Take the screenshot first — `XCUIApplication.frame` triggers a full
    // accessibility snapshot and has been observed to hang for tens of
    // seconds in the failure path on slow runners. The screenshot
    // doesn't, so it's our priority artefact.
    let png = app.application.screenshot().pngRepresentation
    let pngURL = dir.appendingPathComponent("\(basename).png")
    do { try png.write(to: pngURL) } catch {
      add(XCTAttachment(string: "Failed to write \(pngURL.lastPathComponent): \(error)"))
    }
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.lifetime = .keepAlways
    attachment.name = "\(basename).png"
    add(attachment)
    let screenSize = NSScreen.main?.frame.size ?? .zero
    print(
      "[MoolahUITestCase] CAPTURE \(basename) "
        + "screen=\(Int(screenSize.width))x\(Int(screenSize.height))"
    )
  }

  private func nextSnapshotCounter() -> Int {
    let table = Self.failureSnapshotCounters
    let next = ((table.object(forKey: self)?.intValue) ?? 0) + 1
    table.setObject(NSNumber(value: next), forKey: self)
    return next
  }

  // MARK: - Internal: artefact collection

  func collectFailureArtefacts(for app: MoolahApp, succeeded: Bool) {
    if succeeded { return }

    let dir = artefactDirectory(for: name)
    do {
      try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true)
    } catch {
      // Recording the failure to attach is itself best-effort; keep going.
      add(XCTAttachment(string: "Failed to create artefact dir: \(error)"))
      return
    }

    // Print the path so `scripts/test-ui.sh` can grep it out and copy the
    // artefacts back into `.agent-tmp/`, and attach an XCTAttachment so the
    // test navigator surfaces it.
    print("[MoolahUITestCase] ARTEFACT_DIR \(dir.path)")
    add(XCTAttachment(string: "ui-fail artefacts written to: \(dir.path)\n"))

    write(treeText(for: app), to: dir.appendingPathComponent("tree.txt"))
    write(seedText(for: app), to: dir.appendingPathComponent("seed.txt"))
    write(Trace.render(succeeded: false), to: dir.appendingPathComponent("trace.txt"))
    captureScreenshot(for: app, to: dir.appendingPathComponent("screenshot.png"))

    attachArtefacts(in: dir)
  }

  /// Resolves `<runner tmpdir>/MoolahUITests/ui-fail-<TestName>/`.
  ///
  /// The XCUITest runner runs in a stricter sandbox than the app: writes
  /// to `/private/tmp/` fail with "Operation not permitted" on current
  /// macOS. `FileManager.default.temporaryDirectory` resolves to the
  /// runner's own per-process tmpdir under `/var/folders/.../T/` which
  /// the runner can freely create inside and the developer's shell can
  /// still read (same uid) without TCC prompts. `scripts/test-ui.sh`
  /// greps the `[MoolahUITestCase] ARTEFACT_DIR` lines out of
  /// xcodebuild's stdout and copies each artefact dir back into
  /// `<repo-root>/.agent-tmp/` after `xcodebuild test` exits.
  private func artefactDirectory(for testName: String) -> URL {
    let cleanName =
      testName
      .replacingOccurrences(of: "-", with: "_")
      .replacingOccurrences(of: "[", with: "")
      .replacingOccurrences(of: "]", with: "")
      .replacingOccurrences(of: " ", with: "_")
    return FileManager.default.temporaryDirectory
      .appendingPathComponent("MoolahUITests", isDirectory: true)
      .appendingPathComponent("ui-fail-\(cleanName)", isDirectory: true)
  }

  // MARK: - Artefact contents

  private func treeText(for app: MoolahApp) -> String {
    var lines: [String] = []
    lines.append("# accessibility tree (identifier | type | label | value | frame)")
    let screenSize = NSScreen.main?.frame.size ?? .zero
    lines.append(
      "# screen size: \(Int(screenSize.width))x\(Int(screenSize.height))"
    )
    if let focusedIdentifier = currentFocusedIdentifier(in: app) {
      lines.append("# focused element: \(focusedIdentifier)")
    } else {
      lines.append("# focused element: (none — no element has keyboard focus)")
    }
    lines.append(
      "# (per-element focus is omitted — `XCUIElementSnapshot` does not expose it.)")
    lines.append("")
    let snapshot = try? app.application.snapshot()
    if let snapshot { appendTreeSnapshot(snapshot: snapshot, depth: 0, into: &lines) }
    return lines.joined(separator: "\n") + "\n"
  }

  /// Walks the live element tree once to find the currently focused
  /// element, returning its identifier (or label / type if no identifier
  /// is set). At most one element has keyboard focus at a time.
  private func currentFocusedIdentifier(in app: MoolahApp) -> String? {
    let elements = app.application.descendants(matching: .any).allElementsBoundByIndex
    for element in elements where (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false {
      if !element.identifier.isEmpty { return element.identifier }
      if !element.label.isEmpty { return "(label: \(element.label))" }
      return "(\(element.elementType))"
    }
    return nil
  }

  private func appendTreeSnapshot(
    snapshot: XCUIElementSnapshot, depth: Int, into lines: inout [String]
  ) {
    let indent = String(repeating: "  ", count: depth)
    let identifier = snapshot.identifier.isEmpty ? "—" : snapshot.identifier
    let type = String(describing: snapshot.elementType)
    let label =
      snapshot.label.isEmpty ? "—" : snapshot.label.replacingOccurrences(of: "\n", with: " ")
    let value = (snapshot.value as? String).map { $0.isEmpty ? "—" : $0 } ?? "—"
    let frame = snapshot.frame
    let frameStr =
      "(\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.size.width))x\(Int(frame.size.height)))"
    lines.append(
      "\(indent)\(identifier) | \(type) | \(label) | \(value) | \(frameStr)"
    )
    for child in snapshot.children {
      appendTreeSnapshot(snapshot: child, depth: depth + 1, into: &lines)
    }
  }

  private func seedText(for app: MoolahApp) -> String {
    var lines: [String] = []
    lines.append("seed: \(app.seed.rawValue)")
    lines.append("")
    switch app.seed {
    case .tradeBaseline:
      appendTradeBaselineFixtures(into: &lines)
    case .welcomeEmpty:
      lines.append("# fixtures — empty index, no profiles")
    case .welcomeSingleCloudProfile:
      appendWelcomeSingleProfileFixtures(into: &lines)
    case .welcomeMultipleCloudProfiles:
      appendWelcomeMultipleProfileFixtures(into: &lines)
    case .welcomeDownloading:
      lines.append("# SyncProgress driven to .receiving with recordsReceivedThisSession=1234")
      lines.append("# WelcomeView resolves to .heroDownloading(count: 1234)")
    case .sidebarFooterUpToDate:
      lines.append("# SyncProgress driven to .upToDate, lastSettledAt ~5 minutes ago")
    case .sidebarFooterReceiving:
      lines.append("# SyncProgress driven to .receiving with recordsReceivedThisSession=1234")
    case .sidebarFooterSending:
      lines.append("# SyncProgress driven to .upToDate with pendingUploads=12 then settled")
    case .cryptoCatalogPreloaded:
      appendCryptoCatalogPreloadedFixtures(into: &lines)
    case .tradeReady:
      appendTradeReadyFixtures(into: &lines)
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private func appendCryptoCatalogPreloadedFixtures(into lines: inout [String]) {
    let fixtures = UITestFixtures.CryptoCatalogPreloaded.self
    lines.append("# fixtures (CloudKit profile reused from TradeBaseline)")
    lines.append("profile.id      = \(fixtures.profileId)")
    lines.append("profile.label   = \(fixtures.profileLabel)")
    lines.append("profile.currency = \(fixtures.profileCurrencyCode)")
    lines.append("# Catalog override: PreloadedCryptoCatalog (single coin)")
    lines.append("catalog.coingeckoId = \(fixtures.coingeckoId)")
    lines.append("catalog.symbol      = \(fixtures.symbol)")
    lines.append("catalog.name        = \(fixtures.name)")
    lines.append("catalog.chainSlug   = \(fixtures.chainSlug)")
    lines.append("catalog.chainId     = \(fixtures.chainId)")
    lines.append("catalog.contract    = \(fixtures.contractAddress)")
    lines.append("instrument.id       = \(fixtures.instrumentId)")
    lines.append("# Resolution stub: PreloadedTokenResolutionClient")
    lines.append("resolve.coingeckoId        = \(fixtures.coingeckoMappingId)")
    lines.append("resolve.cryptocompareSymbol = \(fixtures.cryptocompareSymbol)")
    lines.append("resolve.binanceSymbol      = \(fixtures.binanceSymbol)")
  }

  private func appendTradeReadyFixtures(into lines: inout [String]) {
    let fixtures = UITestFixtures.TradeReady.self
    lines.append("# fixtures")
    lines.append("profile.id       = \(fixtures.profileId)")
    lines.append("profile.label    = \(fixtures.profileLabel)")
    lines.append("profile.currency = \(fixtures.profileCurrencyCode)")
    lines.append("brokerage.id     = \(fixtures.brokerageAccountId)")
    lines.append("brokerage.name   = \(fixtures.brokerageAccountName)")
    lines.append("instrument.id    = \(fixtures.vgsaxInstrumentId)")
    lines.append("instrument.ticker = \(fixtures.vgsaxTicker)")
    lines.append("instrument.exchange = \(fixtures.vgsaxExchange)")
    lines.append("category.id      = \(fixtures.brokerageCategoryId)")
    lines.append("category.name    = \(fixtures.brokerageCategoryName)")
  }

  private func appendTradeBaselineFixtures(into lines: inout [String]) {
    let fixtures = UITestFixtures.TradeBaseline.self
    lines.append("# fixtures")
    lines.append("profile.id      = \(fixtures.profileId)")
    lines.append("profile.label   = \(fixtures.profileLabel)")
    lines.append("profile.currency = \(fixtures.profileCurrencyCode)")
    lines.append("checking.id     = \(fixtures.checkingAccountId)")
    lines.append("checking.name   = \(fixtures.checkingAccountName)")
    lines.append("brokerage.id    = \(fixtures.brokerageAccountId)")
    lines.append("brokerage.name  = \(fixtures.brokerageAccountName)")
    lines.append("usdSavings.id   = \(fixtures.usdAccountId)")
    lines.append("usdSavings.name = \(fixtures.usdAccountName)")
    lines.append("usdSavings.instrument = \(fixtures.usdAccountInstrumentCode)")
    lines.append("trade.id        = \(fixtures.bhpPurchaseId)")
    lines.append("trade.payee     = \(fixtures.bhpPurchasePayee)")
    lines.append("trade.cents     = \(fixtures.bhpPurchaseAmountCents)")
    lines.append("trade.date      = \(fixtures.bhpPurchaseDate)")
    lines.append("historical.amount.cents = \(fixtures.historicalExpenseAmountCents)")
    for (index, historical) in fixtures.historicalPayees.enumerated() {
      lines.append(
        "historical[\(index)].id/payee/date = "
          + "\(historical.id) / \(historical.payee) / \(historical.date)"
      )
    }
    lines.append(
      "category.groceries.id/name = "
        + "\(fixtures.groceriesCategoryId) / \(fixtures.groceriesCategoryName)")
    lines.append("category.gym.id/name = \(fixtures.gymCategoryId) / \(fixtures.gymCategoryName)")
    lines.append(
      "splitShop.id/payee/date = "
        + "\(fixtures.splitShopId) / \(fixtures.splitShopPayee) / \(fixtures.splitShopDate)")
    lines.append(
      "splitShop.legA.cents / legB.cents = "
        + "\(fixtures.splitShopLegAAmountCents) / \(fixtures.splitShopLegBAmountCents)"
    )
  }

  private func appendWelcomeSingleProfileFixtures(into lines: inout [String]) {
    lines.append("# fixtures")
    lines.append(
      "household.id/label = "
        + "\(UITestWelcomeFixtures.householdProfileId) "
        + "/ \(UITestWelcomeFixtures.householdProfileLabel)"
    )
  }

  private func appendWelcomeMultipleProfileFixtures(into lines: inout [String]) {
    lines.append("# fixtures")
    lines.append(
      "household.id/label = "
        + "\(UITestWelcomeFixtures.householdProfileId) "
        + "/ \(UITestWelcomeFixtures.householdProfileLabel)"
    )
    lines.append(
      "sideBusiness.id/label = "
        + "\(UITestWelcomeFixtures.sideBusinessProfileId) "
        + "/ \(UITestWelcomeFixtures.sideBusinessProfileLabel)"
    )
  }

  private func captureScreenshot(for app: MoolahApp, to url: URL) {
    let screenshot = app.application.screenshot()
    do {
      try screenshot.pngRepresentation.write(to: url)
    } catch {
      add(XCTAttachment(string: "Failed to write screenshot: \(error)"))
    }
  }

  private func write(_ text: String, to url: URL) {
    do {
      try text.write(to: url, atomically: true, encoding: .utf8)
    } catch {
      add(XCTAttachment(string: "Failed to write \(url.lastPathComponent): \(error)"))
    }
  }

  private func attachArtefacts(in dir: URL) {
    let fileManager = FileManager.default
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil)
    else { return }
    for url in entries {
      let attachment = XCTAttachment(contentsOfFile: url)
      attachment.lifetime = .keepAlways
      attachment.name = url.lastPathComponent
      add(attachment)
    }
  }
}
