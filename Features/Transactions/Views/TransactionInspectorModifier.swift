import SwiftUI

/// Attaches a transaction detail inspector (macOS) or sheet (iOS) to a view.
///
/// Use this modifier on the outermost view that fills the NavigationSplitView detail column.
/// Never attach it to a view nested inside another container (e.g., a card or tab) — the
/// inspector would be constrained to that subview's bounds instead of spanning the full window.
struct TransactionInspectorModifier: ViewModifier {
  @Binding var selectedTransaction: Transaction?
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore
  var showRecurrence: Bool = false
  var viewingAccountId: UUID? = nil

  private var isPresented: Binding<Bool> {
    Binding(
      get: { selectedTransaction != nil },
      set: { if !$0 { selectedTransaction = nil } }
    )
  }

  func body(content: Content) -> some View {
    content
      #if os(macOS)
        .inspector(isPresented: isPresented) {
          if let selected = selectedTransaction {
            TransactionDetailView(
              transaction: selected,
              accounts: accounts,
              categories: categories,
              earmarks: earmarks,
              transactionStore: transactionStore,
              showRecurrence: showRecurrence,
              viewingAccountId: viewingAccountId,
              onUpdate: { updated in
                Task { await transactionStore.update(updated) }
                selectedTransaction = updated
              },
              onDelete: { id in
                Task { await transactionStore.delete(id: id) }
                selectedTransaction = nil
              }
            )
            .id(selected.id)
          }
        }
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            if selectedTransaction != nil {
              Button {
                selectedTransaction = nil
              } label: {
                Label("Hide Details", systemImage: "sidebar.trailing")
              }
              .help("Hide Details")
            }
          }
        }
      #else
        .sheet(item: $selectedTransaction) { selected in
          NavigationStack {
            TransactionDetailView(
              transaction: selected,
              accounts: accounts,
              categories: categories,
              earmarks: earmarks,
              transactionStore: transactionStore,
              showRecurrence: showRecurrence,
              viewingAccountId: viewingAccountId,
              onUpdate: { updated in
                Task { await transactionStore.update(updated) }
                selectedTransaction = updated
              },
              onDelete: { id in
                Task { await transactionStore.delete(id: id) }
                selectedTransaction = nil
              }
            )
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                  selectedTransaction = nil
                }
              }
            }
          }
        }
      #endif
  }
}

/// Conditionally applies the transaction inspector. When `enabled` is false,
/// the modifier passes the content through unchanged (parent handles the inspector).
struct OptionalTransactionInspector: ViewModifier {
  let enabled: Bool
  @Binding var selectedTransaction: Transaction?
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore
  var showRecurrence: Bool = false
  var viewingAccountId: UUID? = nil

  func body(content: Content) -> some View {
    if enabled {
      content.transactionInspector(
        selectedTransaction: $selectedTransaction,
        accounts: accounts,
        categories: categories,
        earmarks: earmarks,
        transactionStore: transactionStore,
        showRecurrence: showRecurrence,
        viewingAccountId: viewingAccountId
      )
    } else {
      content
    }
  }
}

extension View {
  func transactionInspector(
    selectedTransaction: Binding<Transaction?>,
    accounts: Accounts,
    categories: Categories,
    earmarks: Earmarks,
    transactionStore: TransactionStore,
    showRecurrence: Bool = false,
    viewingAccountId: UUID? = nil
  ) -> some View {
    modifier(
      TransactionInspectorModifier(
        selectedTransaction: selectedTransaction,
        accounts: accounts,
        categories: categories,
        earmarks: earmarks,
        transactionStore: transactionStore,
        showRecurrence: showRecurrence,
        viewingAccountId: viewingAccountId
      )
    )
  }
}
