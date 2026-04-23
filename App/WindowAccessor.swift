#if os(macOS)
  import AppKit
  import SwiftUI

  /// Exposes the hosting `NSWindow` to SwiftUI view code. Place in `.background(...)`
  /// so layout stays unaffected; `configure` fires on first attach and whenever the
  /// view moves to a different window.
  struct WindowAccessor: NSViewRepresentable {
    let configure: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
      WindowTrackingView(configure: configure)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
  }

  private final class WindowTrackingView: NSView {
    private let configure: @MainActor (NSWindow) -> Void

    init(configure: @escaping @MainActor (NSWindow) -> Void) {
      self.configure = configure
      super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      MainActor.assumeIsolated { configure(window) }
    }
  }
#endif
