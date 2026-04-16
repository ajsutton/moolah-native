# About Moolah Dialog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a custom branded About window to the macOS app, replacing the default system About panel.

**Architecture:** A standalone `AboutView` in a new `Window` scene, wired into the app menu via `CommandGroup(replacing: .appInfo)`. The view uses hardcoded brand colors (an explicit exception for this brand-surface panel). macOS only — conditionally compiled with `#if os(macOS)`.

**Tech Stack:** SwiftUI `Window` scene, `@Environment` for accessibility, `Bundle.main` for version info.

**Spec:** `plans/2026-04-16-about-dialog-design.md`

---

### File Map

| Action | Path | Purpose |
|--------|------|---------|
| Create | `Features/About/AboutView.swift` | The About window view (background, starfield, icon, text, link) |
| Create | `Features/About/AboutCommands.swift` | `Commands` struct replacing `.appInfo` menu item |
| Modify | `App/MoolahApp.swift` | Add `Window` scene and `AboutCommands` to `.commands {}` |

No tests — this is a purely visual, stateless view with no business logic. The view reads from `Bundle.main` and `@Environment` only.

---

### Task 1: Create AboutView

**Files:**
- Create: `Features/About/AboutView.swift`

- [ ] **Step 1: Create the About directory**

```bash
mkdir -p Features/About
```

- [ ] **Step 2: Write AboutView.swift**

```swift
#if os(macOS)
import SwiftUI

/// Custom branded About window replacing the default macOS About panel.
/// This view intentionally uses hardcoded brand colors rather than semantic
/// system colors — it is a brand-surface panel, not a data-display view.
/// Do not replicate this pattern elsewhere.
struct AboutView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityIncreaseContrast) private var increaseContrast
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
      // Background gradient
      LinearGradient(
        colors: [Self.brandSpace, Self.deepVoid, Self.inkNavy],
        startPoint: .top,
        endPoint: .bottom
      )

      // Starfield (hidden for Increase Contrast)
      if !increaseContrast {
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

        divider
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
      if !increaseContrast {
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
    Text("YOUR MONEY, ROCK SOLID.")
      .font(.system(size: 11, weight: .medium))
      .tracking(1.3)
      .foregroundStyle(Self.balanceGold)
  }

  private var versionLabel: some View {
    Text(versionString)
      .font(.system(size: 11, design: .monospaced))
      .tracking(0.2)
      .foregroundStyle(Self.muted)
  }

  private var divider: some View {
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
    Link("moolah.rocks", destination: URL(string: "https://moolah.rocks")!)
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

  private var starfield: some View {
    GeometryReader { geo in
      let stars: [(x: CGFloat, y: CGFloat, size: CGFloat, color: Color, opacity: Double)] = [
        (0.15, 0.10, 2, Self.lightBlue, 0.30),
        (0.70, 0.07, 1.5, Self.balanceGold, 0.25),
        (0.88, 0.22, 1, Self.lightBlue, 0.20),
        (0.08, 0.50, 1.5, Color.white, 0.15),
        (0.92, 0.65, 1, Self.lightBlue, 0.20),
        (0.22, 0.78, 1.5, Self.balanceGold, 0.20),
        (0.68, 0.85, 1, Color.white, 0.15),
        (0.05, 0.35, 1, Self.lightBlue, 0.15),
        (0.50, 0.90, 1.5, Self.lightBlue, 0.20),
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
```

- [ ] **Step 3: Verify the file compiles**

```bash
just build-mac 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Features/About/AboutView.swift
git commit -m "feat: add AboutView with branded dark background and breathing glow"
```

---

### Task 2: Create AboutCommands and wire into MoolahApp

**Files:**
- Create: `Features/About/AboutCommands.swift`
- Modify: `App/MoolahApp.swift`

- [ ] **Step 1: Write AboutCommands.swift**

```swift
#if os(macOS)
import SwiftUI

/// Replaces the default About menu item to open the custom About window.
struct AboutCommands: Commands {
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(replacing: .appInfo) {
      Button("About Moolah") {
        openWindow(id: "about")
      }
    }
  }
}
#endif
```

- [ ] **Step 2: Add the Window scene to MoolahApp.swift**

In `App/MoolahApp.swift`, add the About window scene after the `Settings` scene (inside the `#if os(macOS)` block, after line 224):

```swift
      Window("About Moolah", id: "about") {
        AboutView()
      }
      .windowResizability(.contentSize)
      .windowStyle(.hiddenTitleBar)
```

- [ ] **Step 3: Add AboutCommands to the .commands block**

In `App/MoolahApp.swift`, add `AboutCommands()` inside the `.commands { }` block on macOS (after `ShowHiddenCommands()`, around line 215):

```swift
        AboutCommands()
```

- [ ] **Step 4: Build and verify**

```bash
just build-mac 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Run the app and test the About window**

```bash
just run-mac
```

Test manually:
1. Click "Moolah" menu → "About Moolah" — the branded About window should appear
2. Verify: dark background, app icon with breathing glow, wordmark, tagline, version, website link, copyright
3. Click the website link — should open https://moolah.rocks in the default browser
4. Press Escape — window should close
5. Reopen and close via the window close button

- [ ] **Step 6: Check for compiler warnings**

Use Xcode MCP: `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"` or:

```bash
just build-mac 2>&1 | grep -i warning
```

Fix any warnings in user code (ignore Preview macro warnings).

- [ ] **Step 7: Commit**

```bash
git add Features/About/AboutCommands.swift App/MoolahApp.swift
git commit -m "feat: wire About window into app menu, replacing default About panel"
```

---

### Task 3: Visual polish and accessibility verification

**Files:**
- May modify: `Features/About/AboutView.swift`

- [ ] **Step 1: Test with Reduce Motion enabled**

In System Settings → Accessibility → Display → Reduce motion, enable it. Open the About window. The icon glow should be static (no animation), at opacity 0.7 and scale 1.05x. Disable Reduce Motion when done.

- [ ] **Step 2: Test with Increase Contrast enabled**

In System Settings → Accessibility → Display → Increase contrast, enable it. Open the About window. The starfield dots and glow should be hidden. All text should remain clearly readable. Disable Increase Contrast when done.

- [ ] **Step 3: Test VoiceOver**

Enable VoiceOver (Cmd+F5). Tab through the About window. Verify:
- The app icon reads "Moolah app icon"
- The website link reads "Open moolah.rocks website"
- All text content is read aloud

- [ ] **Step 4: Test keyboard navigation**

- Press Escape — window should dismiss
- Tab should reach the website link
- Return/Space on the focused link should open the website

- [ ] **Step 5: Verify window behavior**

- Window should not be resizable (no resize handles)
- Opening "About Moolah" twice should bring the existing window to front, not create a second one
- Window title bar should be hidden (`.windowStyle(.hiddenTitleBar)`)

- [ ] **Step 6: Fix any issues found, then commit if changes were made**

```bash
git add Features/About/
git commit -m "fix: address accessibility and polish issues in About window"
```
