// SidebarView previews live in their own file so SidebarView.swift stays
// under SwiftLint's file_length budget. Both previews reference internal
// SidebarView APIs and seed an in-memory PreviewBackend; nothing here is
// referenced from production code.

import SwiftUI

@MainActor
private func seedSidebarPreview(backend: any BackendProvider) async {
  // Both `accountStore` and `earmarkStore` are reactive — they load
  // themselves from `init` via `observeAll()`. Seeded rows propagate
  // through the observation streams without an explicit reload here.
  _ = try? await backend.accounts.create(
    Account(name: "Bank", type: .bank, instrument: .AUD),
    openingBalance: InstrumentAmount(quantity: 1000, instrument: .AUD))
  _ = try? await backend.accounts.create(
    Account(name: "Asset", type: .asset, instrument: .AUD),
    openingBalance: InstrumentAmount(quantity: 5000, instrument: .AUD))
  _ = try? await backend.earmarks.create(Earmark(name: "Holiday Fund", instrument: .AUD))
}

#Preview {
  let (backend, _) = PreviewBackend.create()
  let accountStore = AccountStore(
    repository: backend.accounts,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  let earmarkStore = EarmarkStore(
    repository: backend.earmarks,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  // In-memory preview session can't fail in practice: opens an ephemeral
  // GRDB queue with no disk access. A trap here is acceptable in #Preview.
  // swiftlint:disable:next force_try
  let session = try! ProfileSession.preview()

  return NavigationSplitView {
    SidebarView(selection: .constant(nil))
      .environment(accountStore)
      .environment(earmarkStore)
      .environment(session)
      .task {
        await seedSidebarPreview(backend: backend)
      }
  } detail: {
    Text("Detail")
  }
}

#Preview("Empty earmarks") {
  let (backend, _) = PreviewBackend.create()
  let accountStore = AccountStore(
    repository: backend.accounts,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  let earmarkStore = EarmarkStore(
    repository: backend.earmarks,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  // In-memory preview session can't fail in practice: opens an ephemeral
  // GRDB queue with no disk access. A trap here is acceptable in #Preview.
  // swiftlint:disable:next force_try
  let session = try! ProfileSession.preview()

  return NavigationSplitView {
    SidebarView(selection: .constant(nil))
      .environment(accountStore)
      .environment(earmarkStore)
      .environment(session)
      .task {
        // Seed only an account — no earmarks. Validates that the
        // Earmarks section header (and its iOS "+" button) renders in
        // the empty-state, and that the macOS toolbar shows both the
        // "New Account" and "New Earmark" buttons.
        _ = try? await backend.accounts.create(
          Account(name: "Bank", type: .bank, instrument: .AUD),
          openingBalance: InstrumentAmount(quantity: 1000, instrument: .AUD))
      }
  } detail: {
    Text("Detail")
  }
}
