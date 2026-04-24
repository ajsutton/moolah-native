#if os(macOS)
  import SwiftUI

  /// Hidden view hosted by the launcher Window. On `.task` it opens the
  /// main `ProfileWindowView` window and immediately dismisses the
  /// launcher, leaving only that window visible to the UI test driver.
  /// When a specific profile was seeded (`profileId != nil`) the window is
  /// opened with that value so the scene binds directly to it; when the
  /// seed produced no profile (Welcome seeds) `openWindow()` opens the
  /// default `WindowGroup(for:)` window with a nil binding so `WelcomeView`
  /// renders inside it.
  ///
  /// The launcher Window is `.defaultLaunchBehavior(.suppressed)` in
  /// production, so this view is never instantiated outside `--ui-testing`.
  struct UITestingLauncherView: View {
    let profileId: UUID?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
      // 1×1 clear view: the launcher must briefly present a window so its
      // `.task` runs (SceneBuilder cannot conditionally include the
      // launcher Window only under `--ui-testing` because SceneBuilder
      // does not support `if/else`). Minimising the visible footprint
      // keeps any flash unobtrusive in case the dismiss races the
      // profile window opening.
      Color.clear
        .frame(width: 1, height: 1)
        .task {
          // openWindow runs synchronously from the test's perspective but
          // its scene materialisation is asynchronous. Dismissing the
          // launcher immediately afterwards is intentional: drivers
          // tolerate a transient zero-windows gap because
          // `MoolahApp.expectMainWindowVisible` waits for the new window.
          if let profileId {
            openWindow(value: profileId)
          } else {
            openWindow(id: MoolahApp.mainWindowID)
          }
          dismissWindow(id: "ui-testing-launcher")
        }
    }
  }
#endif
