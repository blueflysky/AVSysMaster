import Foundation
import SwiftUI

@MainActor
final class UnifiedModelStore: ObservableObject {
  @Published var draft: UnifiedControlModel = .init()
  @Published private(set) var runtime: UnifiedControlModel = .init()
  @Published var validationErrors: [String] = []

  /// Captured from ControlPageView's GeometryReader so the editor can render a 1:1 preview.
  var runtimeCanvasSize: CGSize = UIScreen.main.bounds.size

  private(set) var snapshots: [UnifiedControlModel] = []
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init() {
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    decoder.dateDecodingStrategy = .iso8601
    encoder.dateEncodingStrategy = .iso8601
  }

  func load() async {
    do {
      let data = try Data(contentsOf: Self.configURL())
      let model = try decoder.decode(UnifiedControlModel.self, from: data)
      runtime = migrated(model)
      draft = runtime
      snapshots = [runtime]
    } catch {
      runtime = .init()
      draft = runtime
      snapshots = [runtime]
    }
  }

  func saveDraft() async throws {
    var output = draft
    output.meta.updatedAt = Date()
    output.meta.snapshotID = UUID().uuidString
    let data = try encoder.encode(output)
    try data.write(to: Self.configURL(), options: .atomic)
    draft = output
  }

  func publishDraft() -> Bool {
    let errors = validate(draft)
    validationErrors = errors
    guard errors.isEmpty else { return false }
    runtime = draft
    snapshots.append(runtime)
    if snapshots.count > 5 {
      snapshots.removeFirst()
    }
    return true
  }

  func rollback() {
    guard snapshots.count >= 2 else { return }
    snapshots.removeLast()
    if let previous = snapshots.last {
      runtime = previous
      draft = previous
    }
  }

  func validate(_ model: UnifiedControlModel) -> [String] {
    var errors: [String] = []
    let deviceIDs = Set(model.devices.map(\.id))
    let commandIDs = Set(model.commands.map(\.id))

    for control in model.controls {
      if control.type == .label || control.type == .border { continue }
      if control.type == .liveMatrixInput || control.type == .liveMatrixOutput { continue }
      guard let binding = control.binding else {
        errors.append("Control \(control.title) missing binding.")
        continue
      }
      if !deviceIDs.contains(binding.deviceID) {
        errors.append("Control \(control.title) missing device binding.")
      }
      if control.type == .matrix || control.type == .liveMatrix || control.type == .volumeLevel { continue }
      if !commandIDs.contains(binding.commandID) {
        errors.append("Control \(control.title) missing command binding.")
      }
      if control.type == .icon {
        if let offID = UUID(uuidString: control.customFields["commandID_off"] ?? ""),
          !commandIDs.contains(offID)
        {
          errors.append("Control \(control.title) missing OFF command binding.")
        }
      }
    }
    return errors
  }

  func updateModelField(key: String, value: String) {
    for index in draft.controls.indices {
      draft.controls[index].customFields[key] = value
    }
  }

  func exportURL() throws -> URL {
    let dir = try Self.appSupportDir()
    let date = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    return dir.appendingPathComponent("export-\(date).json")
  }

  func exportData() throws -> Data {
    try encoder.encode(runtime)
  }

  func importData(_ data: Data) async throws {
    let model = try decoder.decode(UnifiedControlModel.self, from: data)
    draft = migrated(model)
    guard publishDraft() else {
      let detail = validationErrors.isEmpty
        ? "Unknown validation error."
        : validationErrors.map { "• \($0)" }.joined(separator: "\n")
      throw NSError(
        domain: "AVSysMaster.Import", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Import validation failed:\n\(detail)"]
      )
    }
    try await saveDraft()
  }

  private func migrated(_ model: UnifiedControlModel) -> UnifiedControlModel {
    var migrated = model
    if migrated.meta.schemaVersion < 1 {
      migrated.meta.schemaVersion = 1
    }
    return migrated
  }

  private static func appSupportDir() throws -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("AVSysMaster", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private static func configURL() throws -> URL {
    try appSupportDir().appendingPathComponent("unified-model.json")
  }
}
