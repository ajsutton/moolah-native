# About Moolah Dialog — Design Spec

## Overview

A custom About window for the macOS app that replaces the default system About panel. It showcases the brand identity with a dark crystalline aesthetic, breathing icon glow, and the "Solid money. Chill vibes." tagline — turning a standard utility dialog into a small brand moment.

macOS only. No iOS equivalent is needed.

## Visual Design

### Background

Dark branded gradient background evoking the app's "space" aesthetic:

- Gradient: `Brand Space` (#07102E) at top → `Deep Void` (#02050F) at center → `Ink Navy` (#0A2370) at bottom
- Direction: approximately 170° (near-vertical, slight tilt)
- Scattered starfield dots at low opacity (0.15–0.3):
  - Light Blue (#7ABDFF), Balance Gold (#FFD56B), and white
  - ~8–10 dots, varying sizes (1–2px), each with a small matching `box-shadow` glow
  - Static — no animation on the stars

### App Icon

- Standard macOS app icon at 96pt, centered horizontally
- Continuous corner radius matching macOS icon shape (22pt at 96pt size)
- **Breathing glow effect** behind the icon:
  - Radial gradient from Income Blue (#1E64EE, 50% opacity) through Light Blue (#7ABDFF, 20% opacity) to transparent
  - Extends 20pt beyond the icon on all sides
  - 5-second ease-in-out animation cycle:
    - Scale: 0.95x → 1.15x → 0.95x
    - Opacity: 0.35 → 1.0 → 0.35
  - **Reduce Motion:** Animation disabled; static glow at opacity 0.7 and scale 1.05x
  - **Note:** The brand guide discourages looping animations on static elements like the icon. This is an intentional exception — the About window is a one-off brand moment, not a persistent UI surface. The animation is slow enough (5s cycle) to feel ambient rather than attention-seeking, and Reduce Motion disables it entirely.
- **Permanent base shadow** on the icon: `0 4px 20px rgba(30,100,238,0.3)` so there is always some luminance even at the glow's dimmest point

### Content Layout (top to bottom)

All content is center-aligned.

1. **App icon** with breathing glow (described above)
   - Bottom margin: 22pt

2. **App name** — branded wordmark style
   - "moolah" in white (#F8FAFD)
   - ".rocks" in Coral Red (#FF787F)
   - System font, 22pt, bold (weight 700), letter-spacing -0.5px
   - Bottom margin: 4pt

3. **Tagline** — "Solid money. Chill vibes."
   - Balance Gold (#FFD56B)
   - 11pt, medium weight (500), uppercase, letter-spacing 0.12em
   - Bottom margin: 18pt

4. **Version string** — e.g. "1.0.0 · Build 42"
   - Monospaced font (SF Mono / `ui-monospace`)
   - 11pt, Muted color (#AAB4C8), letter-spacing 0.02em
   - Separator is a middle dot (U+00B7: `·`)
   - Format: `{CFBundleShortVersionString} · Build {CFBundleVersion}`
   - Bottom margin: 22pt

5. **Divider**
   - 32px wide, 1px tall, centered
   - Gradient: transparent → Light Blue (#7ABDFF) → transparent, at 40% opacity
   - Bottom margin: 18pt

6. **Website link** — "moolah.rocks"
   - Light Blue (#7ABDFF), 12pt
   - Opens https://moolah.rocks in the default browser on click
   - Uses SwiftUI `Link` view with standard system link styling

7. **Copyright**
   - "© 2026 Adrian Sutton. All rights reserved."
   - Muted color (#AAB4C8), 11pt, `.monospacedDigit()` on the year
   - Top margin: 18pt

### Spacing Summary

- Window padding: 44pt top, 40pt sides, 36pt bottom
- Total content height is approximately 320–360pt depending on text rendering

## Window Behavior

- **Size:** Fixed, approximately 340pt wide. Not resizable.
- **Positioning:** Centered on screen when opened (standard macOS About window behavior).
- **Dismissal:** Closes on Escape key or clicking the close button.
- **Menu item:** Standard "About Moolah" in the app menu (replaces the default About panel).
- **Single instance:** Only one About window can be open at a time.

## Implementation Approach

### Window Declaration

Use a SwiftUI `Window` scene with a fixed ID, opened via `openWindow(id:)` from a custom `CommandGroup(replacing: .appInfo)`.

### View Structure

```
AboutView
├── ZStack (background + starfield + content)
│   ├── Background gradient (LinearGradient)
│   ├── Starfield overlay (static positioned dots)
│   └── VStack (content)
│       ├── Icon container (ZStack: glow + Image)
│       ├── App name (Text with AttributedString or two Text views)
│       ├── Tagline (Text)
│       ├── Version (Text)
│       ├── Divider (custom Rectangle with gradient)
│       ├── Website link (Link)
│       └── Copyright (Text)
```

### Key SwiftUI Considerations

- Use `NSApp.orderFrontStandardAboutPanel` replacement: declare a `Window(id: "about")` scene and replace the About menu item via `CommandGroup(replacing: .appInfo)` to open it with `openWindow(id: "about")`.
- The breathing glow uses a SwiftUI `.animation(.easeInOut(duration: 5).repeatForever(autoreverses: true))` on opacity and scaleEffect state.
- Check `@Environment(\.accessibilityReduceMotion)` to disable animation.
- Check `@Environment(\.accessibilityIncreaseContrast)` — when enabled, hide decorative starfield and glow, ensure all text meets enhanced contrast ratios.
- Pin Dynamic Type to a controlled range with `.dynamicTypeSize(.large)` on the window root view to prevent text overflow in the fixed-width layout.
- Use `.fixedSize()` or `.frame(width: 340)` with `WindowResizability(.contentSize)` to prevent resizing.
- Load version/build from `Bundle.main.infoDictionary`.
- This window intentionally uses hardcoded brand colors rather than semantic system colors. This is an explicit exception for a brand-surface panel — do not replicate this pattern in data-display views.

## Accessibility

- **Reduce Motion:** Glow animation disabled; static glow shown instead (opacity 0.7, scale 1.05x).
- **Increase Contrast:** When enabled, hide decorative starfield dots and icon glow. All text already meets enhanced contrast ratios with the Muted (#AAB4C8) minimum.
- **VoiceOver:** All text elements are readable. The website link has a proper accessibility label ("Open moolah.rocks website"). The icon has an accessibility label ("Moolah app icon").
- **Keyboard:** Escape dismisses the window. The website link is focusable via Tab and activatable via Return/Space.
- **Dynamic Type:** Pinned to `.large` via `.dynamicTypeSize(.large)` on the window root to prevent text overflow in the fixed-width layout.

## Out of Scope

- iOS version of the About screen
- Credits or acknowledgements section
- Support link, privacy policy link (can be added later)
- Easter eggs or hidden interactions
- Localization (English only for now)
