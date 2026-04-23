#if os(iOS)
  import SwiftUI
  import UniformTypeIdentifiers

  // iOS NavigationStack layout extracted from `SettingsView` so the main
  // struct body stays under SwiftLint's `type_body_length` threshold. Every
  // member is view composition over the main struct's shared state.
  extension SettingsView {

    // MARK: - iOS: NavigationStack layout

    var cryptoTokenStoreForSettings: CryptoTokenStore {
      if let session = activeSession {
        return session.cryptoTokenStore
      }
      let fallbackService = CryptoPriceService(
        clients: [CryptoCompareClient(), BinanceClient()],
        tokenRepository: ICloudTokenRepository(),
        resolutionClient: CompositeTokenResolutionClient()
      )
      return CryptoTokenStore(cryptoPriceService: fallbackService)
    }

    var iOSLayout: some View {
      List {
        profilesSection
        addImportProfileSection
        cryptoSection
        importSettingsSection
      }
      .navigationTitle("Settings")
      .overlay {
        if isImporting || isExporting {
          ProgressView(isImporting ? "Importing\u{2026}" : "Exporting\u{2026}")
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
      }
      .sheet(isPresented: $showAddProfile) {
        ProfileFormView()
          .environment(profileStore)
      }
      .sheet(isPresented: $showExportSheet) {
        if let exportFileURL {
          ShareSheetView(url: exportFileURL)
        }
      }
      .alert(deleteAlertTitle, isPresented: $showDeleteAlert) {
        deleteAlertButtons
      } message: {
        deleteAlertMessage
      }
      .fileImporter(
        isPresented: $showImportPicker,
        allowedContentTypes: [.json]
      ) { result in
        Task { await handleImport(result: result) }
      }
      .alert(
        "Import Failed",
        isPresented: .init(
          get: { importError != nil },
          set: { if !$0 { importError = nil } }
        )
      ) {
        Button("OK") { importError = nil }
      } message: {
        if let importError {
          Text(importError)
        }
      }
      .alert(
        "Export Failed",
        isPresented: .init(
          get: { exportError != nil },
          set: { if !$0 { exportError = nil } }
        )
      ) {
        Button("OK") { exportError = nil }
      } message: {
        if let exportError {
          Text(exportError)
        }
      }
    }

    var profilesSection: some View {
      Section("Profiles") {
        ForEach(profileStore.profiles) { profile in
          NavigationLink {
            profileDetailView(for: profile)
              .navigationTitle(profile.label)
          } label: {
            profileRow(profile)
          }
          .swipeActions(edge: .leading) {
            if profile.backendType == .cloudKit,
              profile.id == profileStore.activeProfileID
            {
              Button {
                Task { await handleExport(profile: profile) }
              } label: {
                Label("Export", systemImage: "square.and.arrow.up")
              }
              .tint(.blue)
            }
          }
        }
        .onDelete { indexSet in
          if let index = indexSet.first {
            profileToDelete = profileStore.profiles[index]
            showDeleteAlert = true
          }
        }
      }
    }

    var addImportProfileSection: some View {
      Section {
        Button {
          showAddProfile = true
        } label: {
          Label("Add Profile", systemImage: "plus")
        }
        Button {
          showImportPicker = true
        } label: {
          Label("Import Profile", systemImage: "square.and.arrow.down")
        }
      }
    }

    var cryptoSection: some View {
      Section {
        NavigationLink {
          CryptoSettingsView(store: cryptoTokenStoreForSettings)
        } label: {
          Label("Crypto Tokens", systemImage: "bitcoinsign.circle")
        }
      }
    }

    var importSettingsSection: some View {
      Section("Import") {
        NavigationLink {
          ImportSettingsView()
        } label: {
          Label("CSV Import", systemImage: "tray.and.arrow.down")
        }
        NavigationLink {
          ImportRulesSettingsView()
        } label: {
          Label("Import Rules", systemImage: "list.bullet.rectangle")
        }
      }
    }
  }
#endif
