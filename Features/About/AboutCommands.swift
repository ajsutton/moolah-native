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
