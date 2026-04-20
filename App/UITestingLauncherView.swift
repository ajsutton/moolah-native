#if os(macOS)
  import SwiftUI

  /// Hidden view hosted by the launcher Window. On `.task` it opens the
  /// seeded profile's window via `openWindow(value:)` and immediately
  /// dismisses the launcher, leaving only the profile window visible to
  /// the UI test driver.
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
          guard let profileId else { return }
          // openWindow runs synchronously from the test's perspective but
          // its scene materialisation is asynchronous. Dismissing the
          // launcher immediately afterwards is intentional: drivers
          // tolerate a transient zero-windows gap because
          // `MoolahApp.expectMainWindowVisible` waits for the new window.
          openWindow(value: profileId)
          dismissWindow(id: "ui-testing-launcher")
        }
    }
  }
#endif
