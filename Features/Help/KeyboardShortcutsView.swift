import SwiftUI

/// In-app reference listing every Moolah keyboard shortcut.
/// Opened from Help > Keyboard Shortcuts… (⇧⌘/) on macOS.
struct KeyboardShortcutsView: View {
  var body: some View {
    ScrollView { content }
      .frame(minWidth: 520, minHeight: 640)
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 24) {
      Text("Keyboard Shortcuts").font(.largeTitle.bold())
      fileSection
      editAndViewSections
      navigationSections
      helpSections
    }
    .padding(32)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private var fileSection: some View {
    section("File") {
      row("⌘N", "New Transaction")
      row("⇧⌘N", "New Earmark")
      row("⌃⌘N", "New Account")
      row("⌥⌘N", "New Category")
      row("⇧⌘Q", "Sign Out")
      row("⌘W", "Close Window")
    }
  }

  @ViewBuilder private var editAndViewSections: some View {
    section("Edit") {
      row("⌘F", "Find Transactions")
    }
    section("View") {
      row("⌃⌘S", "Show / Hide Sidebar")
      row("⌥⌘I", "Show / Hide Inspector")
      row("⇧⌘H", "Show / Hide Hidden Accounts")
      row("⌃⌘F", "Enter / Exit Full Screen")
    }
  }

  @ViewBuilder private var navigationSections: some View {
    section("Go") {
      row("⌘1", "Transactions")
      row("⌘2", "Scheduled")
      row("⌘3", "Categories")
      row("⌘4", "Reports")
      row("⌘5", "Analysis")
    }
    section("Transaction") {
      row("Return", "Edit Transaction (on selected row)")
      row("Delete", "Delete Transaction (on selected row)")
      row("⌥⌘1", "Type ▸ Income")
      row("⌥⌘2", "Type ▸ Expense")
      row("⌥⌘3", "Type ▸ Transfer")
      row("⌥⌘4", "Type ▸ Trade")
      row("⌥⌘5", "Type ▸ Custom")
    }
    section("List Navigation") {
      row("↑ / ↓", "Move selection")
      row("Space", "Open inspector for selected item")
      row("Escape", "Deselect / dismiss inspector")
    }
  }

  @ViewBuilder private var helpSections: some View {
    section("Help") {
      row("⇧⌘/", "Open Keyboard Shortcuts")
    }
    section("System") {
      row("⌘,", "Settings")
      row("⌘Q", "Quit Moolah")
      row("⌘H", "Hide Moolah")
      row("⌘M", "Minimize Window")
    }
  }

  @ViewBuilder
  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline)
      content()
    }
  }

  private func row(_ keys: String, _ action: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      Text(keys)
        .font(.body.monospaced())
        .frame(minWidth: 80, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
      Text(action)
      Spacer()
    }
  }
}

#Preview { KeyboardShortcutsView() }
