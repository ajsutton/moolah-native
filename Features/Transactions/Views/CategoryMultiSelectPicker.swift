import SwiftUI

/// Searchable, hierarchical multi-select picker for categories.
/// Hosted as a popover on macOS and pushed via `NavigationLink` on iOS.
struct CategoryMultiSelectPicker: View {
  let categories: Categories
  @Binding var selectedIds: Set<UUID>

  @State private var searchText: String = ""

  var body: some View {
    VStack(spacing: 0) {
      header
      list
    }
    .searchable(text: $searchText, prompt: "Search categories")
    #if os(iOS)
      .navigationTitle("Categories")
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }

  private var header: some View {
    HStack {
      Spacer()
      Button("Clear") { selectedIds.removeAll() }
        .disabled(selectedIds.isEmpty)
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
  }

  private var list: some View {
    List {
      if categories.roots.isEmpty {
        Text("No categories available").foregroundStyle(.secondary)
      } else if visibleEntries.isEmpty {
        Text("No matches").foregroundStyle(.secondary)
      } else {
        ForEach(visibleEntries, id: \.category.id) { entry in
          row(for: entry)
        }
      }
    }
  }

  private var visibleEntries: [Categories.FlatEntry] {
    let all = categories.flattenedByPath()
    guard !searchText.isEmpty else { return all }
    return all.filter { $0.path.localizedCaseInsensitiveContains(searchText) }
  }

  private func indentLevel(for entry: Categories.FlatEntry) -> Int {
    searchText.isEmpty ? entry.path.split(separator: ":").count - 1 : 0
  }

  @ViewBuilder
  private func row(for entry: Categories.FlatEntry) -> some View {
    let label = searchText.isEmpty ? entry.category.name : entry.path
    Toggle(
      isOn: Binding(
        get: { selectedIds.contains(entry.category.id) },
        set: { isOn in
          if isOn {
            selectedIds.insert(entry.category.id)
          } else {
            selectedIds.remove(entry.category.id)
          }
        }
      )
    ) {
      Text(label)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.leading, CGFloat(indentLevel(for: entry) * 16))
    }
  }
}

#Preview {
  @Previewable @State var selected: Set<UUID> = []

  let groceries = Category(name: "Groceries")
  let costco = Category(name: "Costco", parentId: groceries.id)
  let farmers = Category(name: "Farmers Market", parentId: groceries.id)
  let transport = Category(name: "Transport")
  let fuel = Category(name: "Fuel", parentId: transport.id)

  let categories = Categories(from: [
    groceries, costco, farmers, transport, fuel,
  ])

  return CategoryMultiSelectPicker(
    categories: categories,
    selectedIds: $selected
  )
  .frame(width: 320, height: 420)
}
