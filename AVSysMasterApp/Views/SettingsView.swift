import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @EnvironmentObject private var modelStore: UnifiedModelStore
  @Environment(\.dismiss) private var dismiss

  // Import state
  @State private var importShown = false
  @State private var pendingImportURL: URL?
  @State private var showImportConfirmation = false
  @State private var isImporting = false

  // Export state
  @State private var exportShown = false
  @State private var exportDoc = UnifiedModelDocument()
  @State private var exportFilename = "avsysmaster-config"

  // Fullscreen editor
  @State private var editorFullscreen = false

  // Alert
  @State private var alertMessage: AlertMessage?

  // MARK: - Body

  var body: some View {
    NavigationStack {
      TabView {
        EditorPageView(onRequestFullscreen: { editorFullscreen = true })
          .tabItem { Label(L10n.editor, systemImage: "square.grid.3x3") }
        DeviceCommandEditorView()
          .tabItem { Label(L10n.devices, systemImage: "cpu") }
        UIStyleSettingsView()
          .tabItem { Label("Style", systemImage: "paintbrush") }
        ModelEditorView()
          .tabItem { Label(L10n.modelEditor, systemImage: "square.and.pencil") }
        TriggerRulesView()
          .tabItem { Label("触发规则", systemImage: "bolt.horizontal") }
        OperationLogView()
          .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
      }
      .navigationTitle(L10n.settings)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Done") { dismiss() }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
          importButton
          exportMenu
        }
      }
    }
    // Import — file picker
    .fileImporter(isPresented: $importShown, allowedContentTypes: [.json]) { result in
      switch result {
      case .success(let url):
        pendingImportURL = url
        showImportConfirmation = true
      case .failure(let error):
        alertMessage = AlertMessage(message: error.localizedDescription)
      }
    }
    // Import — confirmation before overwrite
    .confirmationDialog(
      "Replace Configuration?",
      isPresented: $showImportConfirmation,
      titleVisibility: .visible
    ) {
      Button("Replace", role: .destructive) {
        if let url = pendingImportURL { runImport(url: url) }
      }
      Button("Cancel", role: .cancel) { pendingImportURL = nil }
    } message: {
      Text("The current configuration will be completely replaced by the imported file. This cannot be undone.")
    }
    // Export — file saver
    .fileExporter(
      isPresented: $exportShown,
      document: exportDoc,
      contentType: .json,
      defaultFilename: exportFilename
    ) { result in
      if case .failure(let error) = result {
        alertMessage = AlertMessage(message: error.localizedDescription)
      }
    }
    // Shared alert
    .alert(item: $alertMessage) { item in
      Alert(title: Text(item.message))
    }
    // Loading overlay during import
    .overlay {
      if isImporting {
        ZStack {
          Color.black.opacity(0.35).ignoresSafeArea()
          VStack(spacing: 14) {
            ProgressView()
              .scaleEffect(1.4)
              .tint(.white)
            Text("Importing…")
              .font(.subheadline.weight(.medium))
              .foregroundStyle(.white)
          }
          .padding(28)
          .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
      }
    }
    // Fullscreen editor
    .fullScreenCover(isPresented: $editorFullscreen) {
      EditorPageView(isFullscreen: true)
        .environmentObject(modelStore)
    }
  }

  // MARK: - Toolbar buttons

  private var importButton: some View {
    Button {
      importShown = true
    } label: {
      Label(L10n.importConfig, systemImage: "square.and.arrow.down")
    }
    .disabled(isImporting)
  }

  private var exportMenu: some View {
    Menu {
      Button("Save to Files…", systemImage: "folder") {
        prepareExport()
      }
      ShareLink(
        item: makeShareURL(),
        preview: SharePreview(
          "AVSysMaster Config",
          image: Image(systemName: "doc.badge.gearshape")
        )
      ) {
        Label("Share…", systemImage: "square.and.arrow.up")
      }
    } label: {
      Label(L10n.exportConfig, systemImage: "square.and.arrow.up")
    }
    .disabled(isImporting)
  }

  // MARK: - Import logic

  private func runImport(url: URL) {
    isImporting = true
    let accessed = url.startAccessingSecurityScopedResource()
    Task {
      defer { if accessed { url.stopAccessingSecurityScopedResource() } }
      do {
        let data = try Data(contentsOf: url)
        try await modelStore.importData(data)
        await MainActor.run {
          isImporting = false
          alertMessage = AlertMessage(message: "✓ Configuration imported successfully.")
        }
      } catch {
        await MainActor.run {
          isImporting = false
          alertMessage = AlertMessage(message: error.localizedDescription)
        }
      }
    }
  }

  // MARK: - Export logic

  private func prepareExport() {
    do {
      let data = try modelStore.exportData()
      exportDoc = UnifiedModelDocument(data: data)
      exportFilename = makeDateFilename()
      exportShown = true
    } catch {
      alertMessage = AlertMessage(message: error.localizedDescription)
    }
  }

  /// Writes export data to a temp file and returns its URL for sharing.
  private func makeShareURL() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(makeDateFilename()).json")
    if let data = try? modelStore.exportData() {
      try? data.write(to: url)
    }
    return url
  }

  private func makeDateFilename() -> String {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyyMMdd-HHmmss"
    return "avsysmaster-\(fmt.string(from: Date()))"
  }
}
