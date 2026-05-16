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
  ///   - collapsed: When `true`, programmatically collapses the top pane to
  ///     zero, preserving the user's divider position for restoration on
  ///     expand. The transition is instant.
  ///   - defaults: `UserDefaults` instance probed for an existing
  ///     autosaved divider position. Defaults to `.moolahShared`; tests can
  ///     inject an isolated suite to avoid leaking saved frames between
  ///     runs.
  ///   - top: The top pane content.
  ///   - bottom: The bottom pane content.
  struct ResizableVSplit<Top: View, Bottom: View>: NSViewRepresentable {
    let autosaveName: String
    let initialTopHeight: CGFloat
    let minTopHeight: CGFloat
    let minBottomHeight: CGFloat
    let collapsed: Bool
    let defaults: UserDefaults
    let top: () -> Top
    let bottom: () -> Bottom

    init(
      autosaveName: String,
      initialTopHeight: CGFloat,
      minTopHeight: CGFloat = 80,
      minBottomHeight: CGFloat = 200,
      collapsed: Bool = false,
      defaults: UserDefaults = .moolahShared,
      @ViewBuilder top: @escaping () -> Top,
      @ViewBuilder bottom: @escaping () -> Bottom
    ) {
      self.autosaveName = autosaveName
      self.initialTopHeight = initialTopHeight
      self.minTopHeight = minTopHeight
      self.minBottomHeight = minBottomHeight
      self.collapsed = collapsed
      self.defaults = defaults
      self.top = top
      self.bottom = bottom
    }

    func makeCoordinator() -> Coordinator {
      Coordinator(
        autosaveName: autosaveName,
        initialTopHeight: initialTopHeight,
        minTopHeight: minTopHeight,
        minBottomHeight: minBottomHeight
      )
    }

    func makeNSView(context: Context) -> NSSplitView {
      let split = NSSplitView()
      split.isVertical = false
      split.dividerStyle = .thin

      let topHost = NSHostingView(rootView: top())
      let bottomHost = NSHostingView(rootView: bottom())
      topHost.translatesAutoresizingMaskIntoConstraints = false
      bottomHost.translatesAutoresizingMaskIntoConstraints = false

      split.addArrangedSubview(topHost)
      split.addArrangedSubview(bottomHost)

      context.coordinator.topHost = topHost
      context.coordinator.bottomHost = bottomHost
      context.coordinator.splitView = split
      // Set splitView before the delegate so no delegate callback can
      // fire with a nil splitView.
      split.delegate = context.coordinator

      // Order matters: autosaveName triggers a restore attempt, so we
      // only apply the initial height when no saved frame exists yet.
      let hasSavedFrames =
        defaults.object(
          forKey: "NSSplitView Subview Frames \(autosaveName)") != nil
      split.autosaveName = autosaveName

      if !hasSavedFrames {
        let height = initialTopHeight
        Task { @MainActor [weak split] in
          split?.setPosition(height, ofDividerAt: 0)
        }
      }

      context.coordinator.appliedCollapsed = false
      return split
    }

    func updateNSView(_ nsView: NSSplitView, context: Context) {
      context.coordinator.topHost?.rootView = top()
      context.coordinator.bottomHost?.rootView = bottom()
      context.coordinator.setCollapsed(collapsed, animated: false)
    }

    // `Coordinator` is nested in the generic `ResizableVSplit`, and Swift
    // forbids conforming a class from a generic context to an `@objc`
    // protocol (`NSSplitViewDelegate`) in an extension. The conformance
    // must stay on the class declaration; the delegate methods are grouped
    // under the `// MARK: NSSplitViewDelegate` section below.
    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
      var topHost: NSHostingView<Top>?
      var bottomHost: NSHostingView<Bottom>?
      weak var splitView: NSSplitView?
      let autosaveName: String
      let initialTopHeight: CGFloat
      let minTopHeight: CGFloat
      let minBottomHeight: CGFloat

      /// True while a programmatic collapse is in effect. Lets the
      /// divider travel below `minTopHeight` (that floor only
      /// constrains user drags, not the scroll-driven collapse).
      var isCollapsing = false
      /// The divider position to restore when expanding. Captured at collapse
      /// time so the user's dragged / autosaved size returns. Not updated
      /// while collapsed: the zero-height top pane offers no draggable surface.
      var savedDividerPosition: CGFloat?
      /// Last value handed to `setCollapsed` so a no-op `updateNSView`
      /// doesn't re-trigger the transition.
      var appliedCollapsed = false

      init(
        autosaveName: String,
        initialTopHeight: CGFloat,
        minTopHeight: CGFloat,
        minBottomHeight: CGFloat
      ) {
        self.autosaveName = autosaveName
        self.initialTopHeight = initialTopHeight
        self.minTopHeight = minTopHeight
        self.minBottomHeight = minBottomHeight
      }

      func setCollapsed(_ collapsed: Bool, animated: Bool) {
        guard collapsed != appliedCollapsed else { return }
        appliedCollapsed = collapsed
        if collapsed {
          applyCollapse()
        } else {
          applyExpand()
        }
      }

      private func applyCollapse() {
        guard let split = splitView else { return }
        // Divider 0's position is the bottom edge of the top pane,
        // i.e. the top arranged subview's current height. That's the
        // reciprocal of `setPosition(_:ofDividerAt:)`.
        savedDividerPosition = split.arrangedSubviews.first?.frame.height
        // Clear the autosave name before moving the divider so the transient
        // 0 position is never persisted. NSSplitView applies an autosaveName
        // assignment synchronously, so it is in effect before the deferred
        // setPosition runs.
        split.autosaveName = ""
        isCollapsing = true
        Task { @MainActor [weak split] in
          split?.setPosition(0, ofDividerAt: 0)
        }
      }

      private func applyExpand() {
        isCollapsing = false
        guard let split = splitView else { return }
        let target = savedDividerPosition ?? initialTopHeight
        split.setPosition(target, ofDividerAt: 0)
        // Resume persistence from the restored (user-chosen) position.
        split.autosaveName = autosaveName
      }

      // MARK: NSSplitViewDelegate

      func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
      ) -> CGFloat {
        // While collapsing, allow the top pane to reach 0. Otherwise
        // enforce the user-drag floor.
        isCollapsing ? 0 : max(proposedMinimumPosition, minTopHeight)
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
