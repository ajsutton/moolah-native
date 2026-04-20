import SwiftUI

struct CategoryDetailView: View {
  let category: Category
  let categories: Categories
  let onUpdate: (Category) -> Void
  let onDelete: (UUID, UUID?) -> Void

  @State private var editedName: String
  @State private var showDeleteSheet = false

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
          showDeleteSheet = true
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
    .sheet(isPresented: $showDeleteSheet) {
      DeleteCategorySheet(
        category: category,
        replacements: replacementCandidates,
        onCancel: { showDeleteSheet = false },
        onConfirm: { replacementId in
          showDeleteSheet = false
          onDelete(category.id, replacementId)
        }
      )
    }
  }

  private var replacementCandidates: [Category] {
    categories.roots.filter { $0.id != category.id }
  }

  private func saveChanges() {
    var updated = category
    updated.name = editedName
    onUpdate(updated)
  }
}

private struct DeleteCategorySheet: View {
  let category: Category
  let replacements: [Category]
  let onCancel: () -> Void
  let onConfirm: (UUID?) -> Void

  @State private var selectedReplacementId: UUID?

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(message)
            .font(.body)
        }

        if !replacements.isEmpty {
          Section("Reassign Transactions") {
            Picker("Replacement Category", selection: $selectedReplacementId) {
              Text("None (unassign)").tag(UUID?.none)
              ForEach(replacements) { candidate in
                Text(candidate.name).tag(Optional(candidate.id))
              }
            }
          }
        }

        Section {
          Button("Delete Category", role: .destructive) {
            onConfirm(selectedReplacementId)
          }
        }
      }
      .navigationTitle("Delete \(category.name)")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: onCancel)
        }
      }
    }
    #if os(macOS)
      .frame(minWidth: 400, minHeight: 300)
    #endif
  }

  private var message: String {
    if replacements.isEmpty {
      return "This will permanently delete this category."
    }
    return
      "Choose a replacement category for transactions and subcategories, or leave unset to unassign them."
  }
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
