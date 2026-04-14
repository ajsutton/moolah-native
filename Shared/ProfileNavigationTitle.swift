import SwiftUI

/// ViewModifier that appends the profile label to the navigation title on macOS
/// when multiple profiles are configured. On iOS, shows the title as-is.
private struct ProfileNavigationTitle: ViewModifier {
  let title: String
  @Environment(ProfileSession.self) private var session
  @Environment(ProfileStore.self) private var profileStore

  /// Read the label from ProfileStore (which is @Observable and updates when the profile
  /// is renamed) instead of ProfileSession.profile.label (which is a let and never changes).
  private var profileLabel: String {
    profileStore.profiles.first { $0.id == session.profile.id }?.label ?? session.profile.label
  }

  func body(content: Content) -> some View {
    #if os(macOS)
      if profileStore.profiles.count > 1 {
        content.navigationTitle("\(title) - \(profileLabel)")
      } else {
        content.navigationTitle(title)
      }
    #else
      content.navigationTitle(title)
    #endif
  }
}

extension View {
  /// Sets the navigation title, appending the profile label on macOS when multiple profiles exist.
  func profileNavigationTitle(_ title: String) -> some View {
    modifier(ProfileNavigationTitle(title: title))
  }
}
