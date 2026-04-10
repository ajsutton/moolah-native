import SwiftUI

/// A container that adds a full-screen expand button to chart content on iOS.
/// On macOS, the chart is rendered as-is without an expand button.
struct ExpandableChart<Content: View>: View {
  let title: String
  @ViewBuilder let content: () -> Content

  @State private var isExpanded = false

  var body: some View {
    ZStack(alignment: .topTrailing) {
      content()

      #if os(iOS)
        Button {
          isExpanded = true
        } label: {
          Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.caption)
            .padding(8)
            .background(.ultraThinMaterial, in: Circle())
        }
        .padding(8)
        .accessibilityLabel("View \(title) full screen")
        .fullScreenCover(isPresented: $isExpanded) {
          NavigationStack {
            content()
              .padding()
              .navigationTitle(title)
              .navigationBarTitleDisplayMode(.inline)
              .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                  Button("Done") {
                    isExpanded = false
                  }
                }
              }
          }
        }
      #endif
    }
  }
}
