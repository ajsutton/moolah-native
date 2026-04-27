#if os(macOS)
  import SwiftUI

  /// Hidden view hosted by the launcher Window. On `.task` it opens the
  /// main `ProfileWindowView` window and then stays around as a 1×1
  /// invisible window for the lifetime of the test process. When a
  /// specific profile was seeded (`profileId != nil`) the window is
  /// opened with that value so the scene binds directly to it; when the
  /// seed produced no profile (Welcome seeds) `openWindow(id:)` opens
  /// the default `WindowGroup(for:)` window with a nil binding so
  /// `WelcomeView` renders inside it.
  ///
  /// The launcher Window is `.defaultLaunchBehavior(.suppressed)` in
  /// production, so this view is never instantiated outside
  /// `--ui-testing`. **Why we don't dismiss it:** earlier versions
  /// dismissed the launcher immediately after `openWindow`, but on
  /// cold-start CI runners the dismiss could race ahead of the
  /// open's scene materialisation and leave the app windowless — the
  /// launcher's Window goes away before the WindowGroup spawns its
  /// own, and SwiftUI then has nothing to show (issue #493). Leaving
  /// the launcher around eliminates the race deterministically: a
  /// `Color.clear`/1×1 frame is invisible to users, and UI test
  /// drivers locate elements by accessibility identifier, so a second
  /// content-free window adds nothing to the tree they care about.
  struct UITestingLauncherView: View {
    let profileId: UUID?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
      Color.clear
        .frame(width: 1, height: 1)
        .task {
          if let profileId {
            openWindow(value: profileId)
          } else {
            openWindow(id: MoolahApp.mainWindowID)
          }
        }
    }
  }
#endif
