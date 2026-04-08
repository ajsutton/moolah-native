import SwiftUI

struct CategoryDetailView: View {
  let category: Category
  let categories: Categories
  let onUpdate: (Category) -> Void
  let onDelete: (UUID, UUID?) -> Void

  @State private var editedName: String
  @State private var showDeleteConfirmation = false
  @State private var selectedReplacementId: UUID?

  init(
    category: Category,
    categories: Categories,
    onUpdate: @escaping (Category) -> Void,
    onDelete: @escaping (UUID, UUID?) -> Void
  ) {
    self.category = category
    self.categories = categories
    self.onUpdate = onUpdate
    self.onDelete = onDelete
    _editedName = State(initialValue: category.name)
  }

  var body: some View {
    Form {
      Section("Details") {
        TextField("Name", text: $editedName)

        if category.parentId != nil {
          if let parent = categories.by(id: category.parentId!) {
            LabeledContent("Parent Category") {
              Text(parent.name)
                .foregroundStyle(.secondary)
            }
          }
        }
      }

      Section {
        Button("Delete Category", role: .destructive) {
          showDeleteConfirmation = true
        }
      }
    }
    .navigationTitle("Edit Category")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save", action: saveChanges)
          .disabled(editedName == category.name || editedName.isEmpty)
      }
    }
    .confirmationDialog(
      "Delete Category",
      isPresented: $showDeleteConfirmation,
      presenting: deletionOptions
    ) { options in
      if options.hasReplacements {
        Button("Delete and Reassign", role: .destructive) {
          // Show picker for replacement
          onDelete(category.id, selectedReplacementId)
        }
      }

      Button("Delete Without Replacement", role: .destructive) {
        onDelete(category.id, nil)
      }

      Button("Cancel", role: .cancel) {}
    } message: { options in
      if options.hasReplacements {
        Text(
          "Select a replacement category for transactions and subcategories, or delete without replacement."
        )
      } else {
        Text("This will permanently delete this category.")
      }
    }
  }

  private var deletionOptions: DeletionOptions {
    let replacements = categories.roots.filter { $0.id != category.id }
    return DeletionOptions(hasReplacements: !replacements.isEmpty)
  }

  private func saveChanges() {
    var updated = category
    updated.name = editedName
    onUpdate(updated)
  }
}

private struct DeletionOptions {
  let hasReplacements: Bool
}

#Preview {
  let groceriesId = UUID()
  let fruitId = UUID()
  let categories = Categories(from: [
    Category(id: groceriesId, name: "Groceries"),
    Category(id: fruitId, name: "Fruit", parentId: groceriesId),
    Category(name: "Transport"),
  ])

  NavigationStack {
    CategoryDetailView(
      category: categories.by(id: fruitId)!,
      categories: categories,
      onUpdate: { _ in },
      onDelete: { _, _ in }
    )
  }
}
