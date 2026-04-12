import SwiftData
import SwiftUI

struct CategoriesView: View {
  let categoryStore: CategoryStore

  @State private var showCreateSheet = false
  @State private var selectedCategory: Category?
  @State private var showDetailSheet = false
  @State private var searchText = ""

  var body: some View {
    Group {
      #if os(macOS)
        HStack(spacing: 0) {
          listView

          if let selected = selectedCategory {
            Divider()

            CategoryDetailView(
              category: selected,
              categories: categoryStore.categories,
              onUpdate: { updated in
                Task {
                  if await categoryStore.update(updated) != nil {
                    selectedCategory = updated
                  }
                }
              },
              onDelete: { id, replacementId in
                Task {
                  if await categoryStore.delete(id: id, withReplacement: replacementId) {
                    selectedCategory = nil
                  }
                }
              }
            )
            .frame(width: UIConstants.detailPanelWidth)
          }
        }
      #else
        listView
          .sheet(item: $selectedCategory) { selected in
            NavigationStack {
              CategoryDetailView(
                category: selected,
                categories: categoryStore.categories,
                onUpdate: { updated in
                  Task {
                    if await categoryStore.update(updated) != nil {
                      selectedCategory = updated
                    }
                  }
                },
                onDelete: { id, replacementId in
                  Task {
                    if await categoryStore.delete(id: id, withReplacement: replacementId) {
                      selectedCategory = nil
                    }
                  }
                }
              )
              .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                  Button("Done") {
                    selectedCategory = nil
                  }
                }
              }
            }
          }
      #endif
    }
    .sheet(isPresented: $showCreateSheet) {
      CreateCategorySheet(
        categories: categoryStore.categories,
        onCreate: { newCategory in
          Task {
            _ = await categoryStore.create(newCategory)
            showCreateSheet = false
          }
        }
      )
    }
  }

  private var filteredCategories: [Category] {
    if searchText.isEmpty {
      return categoryStore.categories.roots
    }
    return categoryStore.categories.roots.filter {
      matchesSearch($0)
    }
  }

  private func matchesSearch(_ category: Category) -> Bool {
    if category.name.localizedCaseInsensitiveContains(searchText) {
      return true
    }
    // Also check children
    return categoryStore.categories.children(of: category.id).contains {
      $0.name.localizedCaseInsensitiveContains(searchText)
    }
  }

  private var listView: some View {
    List(selection: $selectedCategory) {
      ForEach(filteredCategories) { category in
        CategoryNodeView(
          category: category,
          categories: categoryStore.categories
        )
        .accessibilityLabel(category.name)
        .tag(category)
        .contextMenu {
          Button("Edit", systemImage: "pencil") {
            selectedCategory = category
          }
        }
        .swipeActions(edge: .leading) {
          Button {
            selectedCategory = category
          } label: {
            Label("Edit", systemImage: "pencil")
          }
          .tint(.blue)
        }
      }
    }
    #if os(macOS)
      .listStyle(.inset)
    #else
      .listStyle(.plain)
    #endif
    .profileNavigationTitle("Categories")
    .toolbar {
      if categoryStore.isLoading && !categoryStore.categories.roots.isEmpty {
        ToolbarItem(placement: .automatic) {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Refreshing categories")
        }
      }
      ToolbarItem(placement: .primaryAction) {
        Button {
          showCreateSheet = true
        } label: {
          Label("Add Category", systemImage: "plus")
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
      }
    }
    .task {
      await categoryStore.load()
    }
    .refreshable {
      await categoryStore.load()
    }
    .searchable(text: $searchText, prompt: "Search categories")
    .overlay {
      if categoryStore.isLoading && categoryStore.categories.roots.isEmpty {
        ProgressView()
      } else if !categoryStore.isLoading && categoryStore.categories.roots.isEmpty {
        ContentUnavailableView(
          "No Categories",
          systemImage: "tag",
          description: Text("Create a category to start organizing your transactions.")
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
        .contentShape(Rectangle())
    } else {
      DisclosureGroup {
        ForEach(children) { child in
          CategoryNodeView(category: child, categories: categories)
            .tag(child)
        }
      } label: {
        Label(category.name, systemImage: "folder")
      }
    }
  }
}

private struct CreateCategorySheet: View {
  let categories: Categories
  let onCreate: (Category) -> Void

  @State private var name: String = ""
  @State private var selectedParentId: UUID?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section("Details") {
          TextField("Name", text: $name)
        }

        Section("Parent Category") {
          Picker("Parent", selection: $selectedParentId) {
            Text("None (Top-Level)").tag(nil as UUID?)
            ForEach(allCategories) { category in
              Text(category.name).tag(category.id as UUID?)
            }
          }
        }
      }
      .navigationTitle("New Category")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }

        ToolbarItem(placement: .primaryAction) {
          Button("Create") {
            let newCategory = Category(
              name: name,
              parentId: selectedParentId
            )
            onCreate(newCategory)
          }
          .disabled(name.isEmpty)
        }
      }
    }
  }

  private var allCategories: [Category] {
    var result: [Category] = []
    for root in categories.roots {
      result.append(root)
      result.append(contentsOf: categories.children(of: root.id))
    }
    return result
  }
}

#Preview {
  let (backend, _) = PreviewBackend.create()
  let store = CategoryStore(repository: backend.categories)

  NavigationStack {
    CategoriesView(categoryStore: store)
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
