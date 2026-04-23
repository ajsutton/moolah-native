#if os(macOS)
  import SwiftUI

  /// Custom branded About window replacing the default macOS About panel.
  /// This view intentionally uses hardcoded brand colors rather than semantic
  /// system colors — it is a brand-surface panel, not a data-display view.
  /// Do not replicate this pattern elsewhere.
  struct AboutView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var glowActive = false

    // MARK: - Brand Colors

    private static let brandSpace = Color(red: 7 / 255, green: 16 / 255, blue: 46 / 255)
    private static let deepVoid = Color(red: 2 / 255, green: 5 / 255, blue: 15 / 255)
    private static let inkNavy = Color(red: 10 / 255, green: 35 / 255, blue: 112 / 255)
    private static let incomeBlue = Color(red: 30 / 255, green: 100 / 255, blue: 238 / 255)
    private static let lightBlue = Color(red: 122 / 255, green: 189 / 255, blue: 255 / 255)
    private static let coralRed = Color(red: 255 / 255, green: 120 / 255, blue: 127 / 255)
    private static let balanceGold = Color(red: 255 / 255, green: 213 / 255, blue: 107 / 255)
    private static let paper = Color(red: 248 / 255, green: 250 / 255, blue: 253 / 255)
    private static let muted = Color(red: 170 / 255, green: 180 / 255, blue: 200 / 255)

    // MARK: - Version Info

    private var versionString: String {
      let version =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
      let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
      return "\(version) \u{00B7} Build \(build)"
    }

    // MARK: - Body

    var body: some View {
      ZStack {
        // Starfield (hidden for Increase Contrast)
        if colorSchemeContrast != .increased {
          starfield
        }

        // Content
        VStack(spacing: 0) {
          iconWithGlow
            .padding(.bottom, 22)

          appName
            .padding(.bottom, 4)

          tagline
            .padding(.bottom, 18)

          versionLabel
            .padding(.bottom, 22)

          dividerLine
            .padding(.bottom, 18)

          websiteLink

          copyright
            .padding(.top, 18)
        }
      }
      .frame(width: 340)
      .fixedSize()
      .padding(.top, 44)
      .padding(.bottom, 36)
      .padding(.horizontal, 40)
      .background {
        LinearGradient(
          colors: [Self.brandSpace, Self.deepVoid, Self.inkNavy],
          startPoint: .top,
          endPoint: .bottom
        )
      }
      .dynamicTypeSize(.large)
      .onAppear {
        glowActive = true
      }
    }

    // MARK: - Subviews

    private var iconWithGlow: some View {
      ZStack {
        // Breathing glow (hidden for Increase Contrast)
        if colorSchemeContrast != .increased {
          RoundedRectangle(cornerRadius: 36)
            .fill(
              RadialGradient(
                colors: [
                  Self.incomeBlue.opacity(0.5),
                  Self.lightBlue.opacity(0.2),
                  Color.clear,
                ],
                center: .center,
                startRadius: 0,
                endRadius: 68
              )
            )
            .frame(width: 136, height: 136)
            .scaleEffect(glowActive && !reduceMotion ? 1.15 : reduceMotion ? 1.05 : 0.95)
            .opacity(glowActive && !reduceMotion ? 1.0 : reduceMotion ? 0.7 : 0.35)
            .animation(
              reduceMotion
                ? nil
                : .easeInOut(duration: 5).repeatForever(autoreverses: true),
              value: glowActive
            )
        }

        // App icon
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .frame(width: 96, height: 96)
          .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
          .shadow(color: Self.incomeBlue.opacity(0.3), radius: 10, y: 4)
          .accessibilityLabel("Moolah app icon")
      }
    }

    private var appName: some View {
      HStack(spacing: 0) {
        Text("moolah")
          .foregroundStyle(Self.paper)
        Text(".rocks")
          .foregroundStyle(Self.coralRed)
      }
      .font(.system(size: 22, weight: .bold))
      .kerning(-0.5)
    }

    private var tagline: some View {
      Text("Your money, rock solid.")
        .font(.system(size: 11, weight: .medium))
        .textCase(.uppercase)
        .tracking(1.3)
        .foregroundStyle(Self.balanceGold)
    }

    private var versionLabel: some View {
      Text(versionString)
        .font(.system(size: 11, design: .monospaced))
        .tracking(0.2)
        .foregroundStyle(Self.muted)
    }

    private var dividerLine: some View {
      Rectangle()
        .fill(
          LinearGradient(
            colors: [.clear, Self.lightBlue, .clear],
            startPoint: .leading,
            endPoint: .trailing
          )
        )
        .frame(width: 32, height: 1)
        .opacity(0.4)
    }

    private var websiteLink: some View {
      Link(
        "moolah.rocks",
        destination: URL(string: "https://moolah.rocks") ?? URL(fileURLWithPath: "/")
      )
      .font(.system(size: 12))
      .foregroundStyle(Self.lightBlue)
      .accessibilityLabel("Open moolah.rocks website")
    }

    private var copyright: some View {
      Text("© 2026 Adrian Sutton. All rights reserved.")
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(Self.muted)
    }

    // MARK: - Starfield

    private struct Star {
      let x: CGFloat
      let y: CGFloat
      let size: CGFloat
      let color: Color
      let opacity: Double
    }

    private var starfield: some View {
      GeometryReader { geo in
        let stars: [Star] = [
          Star(x: 0.15, y: 0.10, size: 2, color: Self.lightBlue, opacity: 0.30),
          Star(x: 0.70, y: 0.07, size: 1.5, color: Self.balanceGold, opacity: 0.25),
          Star(x: 0.88, y: 0.22, size: 1, color: Self.lightBlue, opacity: 0.20),
          Star(x: 0.08, y: 0.50, size: 1.5, color: Color.white, opacity: 0.15),
          Star(x: 0.92, y: 0.65, size: 1, color: Self.lightBlue, opacity: 0.20),
          Star(x: 0.22, y: 0.78, size: 1.5, color: Self.balanceGold, opacity: 0.20),
          Star(x: 0.68, y: 0.85, size: 1, color: Color.white, opacity: 0.15),
          Star(x: 0.05, y: 0.35, size: 1, color: Self.lightBlue, opacity: 0.15),
          Star(x: 0.50, y: 0.90, size: 1.5, color: Self.lightBlue, opacity: 0.20),
        ]

        ForEach(Array(stars.enumerated()), id: \.offset) { _, star in
          Circle()
            .fill(star.color)
            .frame(width: star.size, height: star.size)
            .shadow(color: star.color, radius: star.size)
            .opacity(star.opacity)
            .position(
              x: geo.size.width * star.x,
              y: geo.size.height * star.y
            )
        }
      }
    }
  }

  #Preview {
    AboutView()
  }
#endif
