import SwiftData
import SwiftUI

struct CategoryTreeView: View {
  let categoryStore: CategoryStore

  var body: some View {
    List {
      ForEach(categoryStore.categories.roots) { category in
        CategoryNodeView(
          category: category,
          categories: categoryStore.categories
        )
      }
    }
    #if os(macOS)
      .listStyle(.inset)
    #else
      .listStyle(.plain)
    #endif
    .navigationTitle("Categories")
    .overlay {
      if categoryStore.isLoading && categoryStore.categories.roots.isEmpty {
        ProgressView()
      } else if !categoryStore.isLoading && categoryStore.categories.roots.isEmpty {
        ContentUnavailableView(
          "No Categories",
          systemImage: "tag",
          description: Text("No categories have been created yet.")
        )
      }
    }
  }
}

private struct CategoryNodeView: View {
  let category: Category
  let categories: Categories

  var body: some View {
    let children = categories.children(of: category.id)

    if children.isEmpty {
      Label(category.name, systemImage: "tag")
    } else {
      DisclosureGroup {
        ForEach(children) { child in
          CategoryNodeView(category: child, categories: categories)
        }
      } label: {
        Label(category.name, systemImage: "folder")
      }
    }
  }
}

#Preview {
  let (backend, _, _) = PreviewBackend.create()
  let store = CategoryStore(repository: backend.categories)

  NavigationStack {
    CategoryTreeView(categoryStore: store)
  }
  .task {
    let groceriesId = UUID()
    for cat in [
      Category(id: groceriesId, name: "Groceries"),
      Category(name: "Fruit", parentId: groceriesId),
      Category(name: "Vegetables", parentId: groceriesId),
      Category(name: "Transport"),
      Category(name: "Entertainment"),
    ] {
      _ = try? await backend.categories.create(cat)
    }
    await store.load()
  }
}
