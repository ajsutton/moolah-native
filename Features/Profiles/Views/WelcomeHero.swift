import SwiftUI

/// Brand colour tokens for the first-run hero. Hex values are scoped to
/// this file and the sibling `ICloudStatusLine` / `ICloudOffChip` /
/// `ICloudArrivalBanner` per design spec §4.1 — never leaked to
/// project-wide `Color` extensions.
///
/// **Access scope:** `internal` by convention — intended only for the
/// sibling welcome views listed above. Do not consume elsewhere: the
/// rest of the app uses semantic system colours per `guides/UI_GUIDE.md` §5.
enum WelcomeBrandColors {
  static let space = Color(red: 0x07 / 255, green: 0x10 / 255, blue: 0x2E / 255)
  static let incomeBlue = Color(red: 0x1E / 255, green: 0x64 / 255, blue: 0xEE / 255)
  static let balanceGold = Color(red: 0xFF / 255, green: 0xD5 / 255, blue: 0x6B / 255)
  static let lightBlue = Color(red: 0x7A / 255, green: 0xBD / 255, blue: 0xFF / 255)
  static let muted = Color(red: 0xAA / 255, green: 0xB4 / 255, blue: 0xC8 / 255)
  static let coralRed = Color(red: 0xFF / 255, green: 0x78 / 255, blue: 0x7F / 255)
}

/// Branded hero used for first-run states 1 (welcome + checking) and 4
/// (iCloud off). Content slot below the CTA receives either
/// ``ICloudStatusLine`` (state 1) or ``ICloudOffChip`` (state 4).
///
/// Colour tokens come from `guides/BRAND_GUIDE.md` §3. Hardcoded hex is
/// scoped to this file per design spec §4.1.
struct WelcomeHero<Footer: View>: View {
  enum Mode: Equatable {
    case checking
    case downloading(received: Int)
  }

  let mode: Mode
  let primaryAction: () -> Void
  @ViewBuilder let footer: () -> Footer

  @FocusState private var focus: Focus?
  @Namespace private var heroNamespace

  private enum Focus: Hashable {
    case primaryCTA
  }

  init(
    mode: Mode = .checking,
    primaryAction: @escaping () -> Void,
    @ViewBuilder footer: @escaping () -> Footer
  ) {
    self.mode = mode
    self.primaryAction = primaryAction
    self.footer = footer
  }

  var body: some View {
    ZStack(alignment: .leading) {
      WelcomeBrandColors.space.ignoresSafeArea()
      heroContent
    }
    .task { focus = .primaryCTA }
    .animation(.easeInOut(duration: 0.4), value: mode)
  }

  private var heroContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      Spacer(minLength: mode == .checking ? 48 : 24)
      eyebrow
      titleBlock
      if case .checking = mode { subhead }
      Spacer()
      ctaButton
      footer().frame(maxWidth: 320, alignment: .leading)
      if case .downloading = mode { downloadFootnote }
      Spacer(minLength: 28)
    }
    .padding(.horizontal, 32)
  }

  private var eyebrow: some View {
    Text("Moolah", comment: "First-run hero eyebrow label")
      .font(.caption.weight(.medium))
      .tracking(1.8)
      .textCase(.uppercase)
      .foregroundStyle(WelcomeBrandColors.balanceGold)
      .matchedGeometryEffect(id: "eyebrow", in: heroNamespace)
      .accessibilityHidden(true)
  }

  private var titleBlock: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Your money,", comment: "First-run hero title line 1")
        .foregroundStyle(.white)
      Text("rock solid.", comment: "First-run hero title line 2")
        .foregroundStyle(WelcomeBrandColors.balanceGold)
    }
    .font(mode == .checking ? .largeTitle.bold() : .title.bold())
    .matchedGeometryEffect(id: "title", in: heroNamespace)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Your money, rock solid.")
    .accessibilityAddTraits(.isHeader)
    .padding(.top, 10)
  }

  private var subhead: some View {
    Text(
      "Money stuff should be boring. Locked down, sorted out, taken care of — so the rest of your life doesn't have to be.",
      comment: "First-run hero subhead"
    )
    .font(.body)
    .foregroundStyle(WelcomeBrandColors.muted)
    .lineLimit(nil)
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: 320, alignment: .leading)
    .padding(.top, 14)
  }

  private var ctaButton: some View {
    Button(action: primaryAction) {
      Text(buttonLabel, comment: "First-run primary CTA")
        .font(mode == .checking ? .headline : .subheadline)
        .frame(maxWidth: 280)
        .frame(minHeight: mode == .checking ? 44 : 36)
    }
    .buttonStyle(PrimaryHeroButtonStyle(prominent: mode == .checking))
    .focusable(true)
    .focused($focus, equals: .primaryCTA)
    .matchedGeometryEffect(id: "cta", in: heroNamespace)
    .onKeyPress(.return) {
      primaryAction()
      return .handled
    }
    .accessibilityIdentifier(ctaIdentifier)
    .padding(.bottom, 12)
  }

  private var ctaIdentifier: String {
    switch mode {
    case .checking: return UITestIdentifiers.Welcome.heroGetStartedButton
    case .downloading: return UITestIdentifiers.Welcome.heroCreateNewButton
    }
  }

  private var buttonLabel: LocalizedStringKey {
    switch mode {
    case .checking: return "Get started"
    case .downloading: return "Create a new profile"
    }
  }

  private var downloadFootnote: some View {
    Text(
      "Download from iCloud will continue in the background.",
      comment: "First-run footnote shown while iCloud data is downloading"
    )
    .font(.footnote)
    .foregroundStyle(WelcomeBrandColors.muted)
    .padding(.top, 8)
    .accessibilityIdentifier(UITestIdentifiers.Welcome.heroDownloadFootnote)
  }
}

private struct PrimaryHeroButtonStyle: ButtonStyle {
  let prominent: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(.white)
      .padding(.vertical, prominent ? 12 : 8)
      .padding(.horizontal, prominent ? 24 : 18)
      .background(
        WelcomeBrandColors.incomeBlue
          .opacity(buttonOpacity(pressed: configuration.isPressed))
      )
      .clipShape(.rect(cornerRadius: 10))
      .contentShape(.rect)
  }

  private func buttonOpacity(pressed: Bool) -> Double {
    let base = prominent ? 1.0 : 0.6
    return pressed ? base * 0.85 : base
  }
}

// The hero renders dark regardless of system colour scheme (always-dark
// brand splash); the default/dark previews are intentionally near-identical.
#Preview("WelcomeHero — default") {
  WelcomeHero(
    primaryAction: {},
    footer: { ICloudStatusLine(state: .checking) }
  )
  .frame(width: 420, height: 560)
}

#Preview("WelcomeHero — dark") {
  WelcomeHero(
    primaryAction: {},
    footer: { ICloudStatusLine(state: .checking) }
  )
  .frame(width: 420, height: 560)
  .preferredColorScheme(.dark)
}

#Preview("WelcomeHero — AX5") {
  WelcomeHero(
    primaryAction: {},
    footer: { ICloudStatusLine(state: .noneFound) }
  )
  .frame(width: 500, height: 720)
  .dynamicTypeSize(.accessibility5)
}

#Preview("WelcomeHero — downloading") {
  WelcomeHero(
    mode: .downloading(received: 1234),
    primaryAction: {},
    footer: { ICloudStatusLine(state: .checkingActive(received: 1234)) }
  )
  .frame(width: 420, height: 560)
}
