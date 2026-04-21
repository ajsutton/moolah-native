import SwiftUI

#if os(macOS)
  import AppKit

  /// A vertical split (panes stacked, divider horizontal) backed by
  /// `NSSplitView` so the divider position can be autosaved in
  /// `UserDefaults`. SwiftUI's `VSplitView` has no binding for the
  /// divider position and doesn't persist it — hence the AppKit wrap.
  ///
  /// Keyboard accessibility: wrapping `NSSplitView` inside
  /// `NSViewRepresentable` means the AppKit keyboard shortcut for
  /// focusing a split-view divider (Option+F6) typically won't reach
  /// this view through the SwiftUI responder chain. Users rely on the
  /// pointer (or the autosaved size) to adjust the split.
  ///
  /// - Parameters:
  ///   - autosaveName: Key under which `NSSplitView` persists the
  ///     divider position. One shared name across all call sites means
  ///     the user's preferred size applies everywhere.
  ///   - initialTopHeight: Height used for the top pane on the very
  ///     first display, before any autosaved frame exists.
  ///   - minTopHeight: Minimum height of the top pane when dragging.
  ///   - minBottomHeight: Minimum height of the bottom pane.
  ///   - top: The top pane content.
  ///   - bottom: The bottom pane content.
  struct ResizableVSplit<Top: View, Bottom: View>: NSViewRepresentable {
    let autosaveName: String
    let initialTopHeight: CGFloat
    let minTopHeight: CGFloat
    let minBottomHeight: CGFloat
    let top: () -> Top
    let bottom: () -> Bottom

    init(
      autosaveName: String,
      initialTopHeight: CGFloat,
      minTopHeight: CGFloat = 80,
      minBottomHeight: CGFloat = 200,
      @ViewBuilder top: @escaping () -> Top,
      @ViewBuilder bottom: @escaping () -> Bottom
    ) {
      self.autosaveName = autosaveName
      self.initialTopHeight = initialTopHeight
      self.minTopHeight = minTopHeight
      self.minBottomHeight = minBottomHeight
      self.top = top
      self.bottom = bottom
    }

    func makeCoordinator() -> Coordinator {
      Coordinator(
        minTopHeight: minTopHeight,
        minBottomHeight: minBottomHeight
      )
    }

    func makeNSView(context: Context) -> NSSplitView {
      let split = NSSplitView()
      split.isVertical = false
      split.dividerStyle = .thin
      split.delegate = context.coordinator

      let topHost = NSHostingView(rootView: top())
      let bottomHost = NSHostingView(rootView: bottom())
      topHost.translatesAutoresizingMaskIntoConstraints = false
      bottomHost.translatesAutoresizingMaskIntoConstraints = false

      split.addArrangedSubview(topHost)
      split.addArrangedSubview(bottomHost)

      context.coordinator.topHost = topHost
      context.coordinator.bottomHost = bottomHost

      // Order matters: autosaveName triggers a restore attempt, so we
      // only apply the initial height when no saved frame exists yet.
      let hasSavedFrames =
        UserDefaults.standard.object(
          forKey: "NSSplitView Subview Frames \(autosaveName)") != nil
      split.autosaveName = autosaveName

      if !hasSavedFrames {
        let height = initialTopHeight
        Task { @MainActor [weak split] in
          split?.setPosition(height, ofDividerAt: 0)
        }
      }

      return split
    }

    func updateNSView(_ nsView: NSSplitView, context: Context) {
      context.coordinator.topHost?.rootView = top()
      context.coordinator.bottomHost?.rootView = bottom()
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
      var topHost: NSHostingView<Top>?
      var bottomHost: NSHostingView<Bottom>?
      let minTopHeight: CGFloat
      let minBottomHeight: CGFloat

      init(minTopHeight: CGFloat, minBottomHeight: CGFloat) {
        self.minTopHeight = minTopHeight
        self.minBottomHeight = minBottomHeight
      }

      func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
      ) -> CGFloat {
        max(proposedMinimumPosition, minTopHeight)
      }

      func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
      ) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.height - minBottomHeight)
      }
    }
  }

  #Preview("Split") {
    ResizableVSplit(
      autosaveName: "preview-resizable-vsplit",
      initialTopHeight: 180
    ) {
      Color.blue.opacity(0.2).overlay(Text("Top"))
    } bottom: {
      Color.green.opacity(0.2).overlay(Text("Bottom"))
    }
    .frame(width: 480, height: 480)
  }
#endif
