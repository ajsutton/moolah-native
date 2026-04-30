import SwiftUI

/// Searchable, hierarchical multi-select picker for categories.
struct CategoryMultiSelectPicker: View {
  let categories: Categories
  @Binding var selectedIds: Set<UUID>

  @State private var searchText: String = ""

  var body: some View {
    list
      .searchable(text: $searchText, prompt: "Search categories")
      .toolbar {
        ToolbarItem(placement: .automatic) {
          Button("Clear") { selectedIds.removeAll() }
            .disabled(selectedIds.isEmpty)
            .help("Clear all selected categories")
        }
      }
      #if os(iOS)
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
      #endif
  }

  private var list: some View {
    List {
      if categories.roots.isEmpty {
        ContentUnavailableView("No Categories", systemImage: "folder")
      } else if visibleEntries.isEmpty {
        ContentUnavailableView.search(text: searchText)
      } else {
        ForEach(visibleEntries, id: \.category.id) { entry in
          row(for: entry)
        }
      }
    }
    .listStyle(.plain)
  }

  private var visibleEntries: [Categories.FlatEntry] {
    categories.flattenedByPath(matching: searchText)
  }

  private func row(for entry: Categories.FlatEntry) -> some View {
    let label = searchText.isEmpty ? entry.category.name : entry.path
    let indent = searchText.isEmpty ? entry.depth : 0
    let isParent = categories.hasChildren(entry.category.id)
    return Toggle(
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
        .lineLimit(2)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.leading, CGFloat(indent * 16))
    .contentShape(.rect)
    .accessibilityLabel(entry.path)
    .accessibilityHint(entry.depth > 0 ? "Subcategory" : "Top-level category")
    .contextMenu {
      if isParent {
        Button("Select all in \(entry.category.name)") {
          selectedIds.formUnion(categories.subtreeIds(of: entry.category.id))
        }
        Button("Deselect all in \(entry.category.name)") {
          selectedIds.subtract(categories.subtreeIds(of: entry.category.id))
        }
      }
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
