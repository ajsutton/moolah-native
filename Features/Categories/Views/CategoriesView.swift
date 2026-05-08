import SwiftData
import SwiftUI

struct CategoriesView: View {
  let categoryStore: CategoryStore

  @State private var showCreateSheet = false
  @State private var selectedCategory: Category?
  @State private var showDetailSheet = false
  @State private var searchText = ""

  private var showCategoryInspectorBinding: Binding<Bool> {
    Binding(
      get: { selectedCategory != nil },
      set: { if !$0 { selectedCategory = nil } }
    )
  }

  var body: some View {
    listView
      #if os(macOS)
        .inspector(isPresented: showCategoryInspectorBinding) {
          if let selected = selectedCategory {
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
            .id(selected.id)
          }
        }
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            if selectedCategory != nil {
              Button {
                selectedCategory = nil
              } label: {
                Label("Hide Details", systemImage: "sidebar.trailing")
              }
              .help("Hide Details")
            }
          }
        }
      #else
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
              ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                  selectedCategory = nil
                }
              }
            }
          }
        }
      #endif
      .sheet(isPresented: $showCreateSheet) {
        CreateCategorySheet(
          categories: categoryStore.categories,
          initialParentId: selectedCategory?.id,
          onCreate: { newCategory in
            Task {
              _ = await categoryStore.create(newCategory)
              showCreateSheet = false
            }
          }
        )
      }
      .focusedSceneValue(\.selectedCategory, $selectedCategory)
      .focusedSceneValue(\.newCategoryAction) {
        showCreateSheet = true
      }
      .onReceive(NotificationCenter.default.publisher(for: .requestCategoryEdit)) { note in
        guard let id = note.object as? UUID,
          let category = categoryStore.categories.by(id: id)
        else { return }
        selectedCategory = category
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
          Button("Edit Category\u{2026}", systemImage: "pencil") {
            selectedCategory = category
          }
        }
        .swipeActions(edge: .leading) {
          Button {
            selectedCategory = category
          } label: {
            Label("Edit Category", systemImage: "pencil")
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
      ToolbarItem(placement: .primaryAction) {
        Button {
          showCreateSheet = true
        } label: {
          Label("Add Category", systemImage: "plus")
        }
      }
    }
    // No `.task { categoryStore.load() }` — the reactive store
    // subscribes to `repository.observeAll()` in init. No
    // `.refreshable` — pull-to-refresh would be a no-op against a live
    // observation.
    .searchable(text: $searchText, prompt: "Search categories")
    .overlay {
      if categoryStore.categories.roots.isEmpty {
        ContentUnavailableView(
          "No Categories",
          systemImage: "tag",
          description: Text(
            PlatformActionVerb.emptyStatePrompt(
              buttonLabel: "+", suffix: "to add your first category."))
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
        .contentShape(.rect)
    } else {
      DisclosureGroup {
        ForEach(children) { child in
          CategoryNodeView(category: child, categories: categories)
            .contentShape(.rect)
            .tag(child)
        }
      } label: {
        Label(category.name, systemImage: "folder")
          .contentShape(.rect)
      }
    }
  }
}

private struct CreateCategorySheet: View {
  /// Single-enum focus model so Tab/Cmd+Return advance through Name →
  /// Parent → Create in the order the form renders. UI_GUIDE §13
  /// requires one optional enum per form with one case per focusable
  /// field; multiple boolean `@FocusState`s don't compose.
  private enum Field: Hashable { case name, parent }

  let categories: Categories
  let initialParentId: UUID?
  let onCreate: (Category) -> Void

  @State private var name: String = ""
  @State private var parent: ParentCategorySelection
  @State private var pickerState = CategoryAutocompleteState()
  @FocusState private var focusedField: Field?
  @Environment(\.dismiss) private var dismiss

  init(
    categories: Categories,
    initialParentId: UUID? = nil,
    onCreate: @escaping (Category) -> Void
  ) {
    self.categories = categories
    self.initialParentId = initialParentId
    self.onCreate = onCreate
    _parent = State(
      initialValue: ParentCategorySelection(
        initialId: initialParentId, in: categories))
  }

  var body: some View {
    NavigationStack {
      form
    }
    #if os(macOS)
      .frame(minWidth: 500, minHeight: 400)
    #endif
  }

  private var visibleSuggestions: [CategorySuggestion] {
    pickerState.visibleSuggestions(for: parent.text, in: categories)
  }

  private var form: some View {
    Form {
      Section("Details") {
        TextField("Name", text: $name)
          .accessibilityLabel("Category name")
          .focused($focusedField, equals: .name)
          .onSubmit { focusedField = .parent }
      }

      Section("Parent Category") {
        CategoryAutocompleteField(
          placeholder: "Parent",
          text: $parent.text,
          highlightedIndex: $pickerState.highlightedIndex,
          suggestionCount: visibleSuggestions.count,
          onTextChange: { _ in openDropdownIfFocused() },
          onAcceptHighlighted: acceptHighlightedParent,
          onCancel: { pickerState.cancel() }
        )
        .focused($focusedField, equals: .parent)
        .accessibilityLabel("Parent category")
        .accessibilityIdentifier(UITestIdentifiers.CreateCategory.parentCategoryField)
      }
    }
    .formStyle(.grouped)
    #if os(macOS)
      .defaultFocus($focusedField, .name)
    #endif
    .onChange(of: focusedField) { _, newField in
      if newField != .parent { handleParentBlur() }
    }
    .overlayPreferenceValue(CategoryPickerAnchorKey.self) { anchor in
      if pickerState.showSuggestions, !visibleSuggestions.isEmpty, let anchor {
        GeometryReader { proxy in
          let rect = proxy[anchor]
          CategorySuggestionDropdown(
            suggestions: visibleSuggestions,
            searchText: parent.text,
            highlightedIndex: $pickerState.highlightedIndex,
            onSelect: selectParent(_:)
          )
          .frame(width: rect.width)
          .offset(x: rect.minX, y: rect.maxY + 4)
        }
      }
    }
    .navigationTitle("New Category")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Create") {
          onCreate(Category(name: name, parentId: parent.id))
        }
        .disabled(name.isEmpty)
        #if os(macOS)
          .keyboardShortcut(.return, modifiers: .command)
        #endif
      }
    }
  }

  private func openDropdownIfFocused() {
    guard focusedField == .parent else { return }
    if pickerState.justSelected {
      pickerState.justSelected = false
    } else {
      pickerState.showSuggestions = true
    }
  }

  private func acceptHighlightedParent() {
    guard
      let index = pickerState.highlightedIndex,
      index < visibleSuggestions.count
    else { return }
    selectParent(visibleSuggestions[index])
  }

  private func selectParent(_ suggestion: CategorySuggestion) {
    pickerState.dismiss()
    parent.commit(suggestion)
  }

  private func handleParentBlur() {
    let highlighted = pickerState.highlightedSuggestion(
      for: parent.text, in: categories)
    pickerState.dismiss()
    parent.commitHighlightedOrNormalise(
      highlighted: highlighted, in: categories)
  }
}

#Preview("Categories List") {
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
    // CategoryStore is reactive — it'll see the seeded categories via
    // `observeAll()` without an explicit load() call.
  }
}

#Preview("Create Category Sheet") {
  let groceriesId = UUID()
  let categories = Categories(from: [
    Category(id: groceriesId, name: "Groceries"),
    Category(name: "Fruit", parentId: groceriesId),
    Category(name: "Vegetables", parentId: groceriesId),
    Category(name: "Transport"),
    Category(name: "Entertainment"),
  ])

  CreateCategorySheet(
    categories: categories,
    initialParentId: groceriesId,
    onCreate: { _ in }
  )
}
