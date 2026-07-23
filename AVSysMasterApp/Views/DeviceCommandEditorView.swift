import SwiftUI

struct DeviceCommandEditorView: View {
  @EnvironmentObject private var modelStore: UnifiedModelStore
  @State private var alertMessage: AlertMessage?
  @State private var activeSheet: SheetKind?

  private enum SheetKind: Identifiable {
    case newDevice
    case editDevice(DeviceItem)
    case newCommand
    case editCommand(CommandItem)

    var id: String {
      switch self {
      case .newDevice: return "newDevice"
      case .editDevice(let d): return "device-\(d.id)"
      case .newCommand: return "newCommand"
      case .editCommand(let c): return "command-\(c.id)"
      }
    }
  }

  var body: some View {
    List {
      Section {
        ForEach(modelStore.draft.devices) { device in
          DeviceRow(device: device)
            .contentShape(Rectangle())
            .onTapGesture {
              activeSheet = .editDevice(device)
            }
        }
        .onDelete { offsets in
          modelStore.draft.devices.remove(atOffsets: offsets)
          persistAndPublish()
        }
      } header: {
        HStack {
          Text(L10n.devices)
          Spacer()
          Button {
            activeSheet = .newDevice
          } label: {
            Image(systemName: "plus")
          }
        }
      }

      Section {
        ForEach(modelStore.draft.commands) { cmd in
          CommandRow(command: cmd)
            .contentShape(Rectangle())
            .onTapGesture {
              activeSheet = .editCommand(cmd)
            }
        }
        .onDelete { offsets in
          modelStore.draft.commands.remove(atOffsets: offsets)
          persistAndPublish()
        }
      } header: {
        HStack {
          Text(L10n.commands)
          Spacer()
          Button {
            activeSheet = .newCommand
          } label: {
            Image(systemName: "plus")
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .sheet(item: $activeSheet) { kind in
      switch kind {
      case .newDevice:
        DeviceFormSheet(existing: nil) { device in
          upsertDevice(device)
        }
      case .editDevice(let device):
        DeviceFormSheet(existing: device) { updated in
          upsertDevice(updated)
        }
      case .newCommand:
        CommandFormSheet(existing: nil) { cmd in
          upsertCommand(cmd)
        }
      case .editCommand(let cmd):
        CommandFormSheet(existing: cmd) { updated in
          upsertCommand(updated)
        }
      }
    }
    .alert(item: $alertMessage) { item in
      Alert(title: Text(item.message))
    }
  }

  private func upsertDevice(_ device: DeviceItem) {
    if let idx = modelStore.draft.devices.firstIndex(where: { $0.id == device.id }) {
      modelStore.draft.devices[idx] = device
    } else {
      modelStore.draft.devices.append(device)
    }
    persistAndPublish()
  }

  private func upsertCommand(_ cmd: CommandItem) {
    if let idx = modelStore.draft.commands.firstIndex(where: { $0.id == cmd.id }) {
      modelStore.draft.commands[idx] = cmd
    } else {
      modelStore.draft.commands.append(cmd)
    }
    persistAndPublish()
  }

  private func persistAndPublish() {
    Task {
      do {
        try await modelStore.saveDraft()
        let published = modelStore.publishDraft()
        if !published {
          alertMessage = AlertMessage(
            message: "Draft saved, but publish failed. Check control device/command bindings."
          )
        }
      } catch {
        alertMessage = AlertMessage(message: "Save failed: \(error.localizedDescription)")
      }
    }
  }
}

// MARK: - Device Row

private struct DeviceRow: View {
  let device: DeviceItem

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text(device.name)
          .font(.headline)
        Text("\(device.host):\(device.port)")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 3) {
        HStack(spacing: 4) {
          Text(device.transport.rawValue.uppercased())
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.blue.opacity(0.12), in: Capsule())
            .foregroundStyle(.blue)
          if device.keepAlive {
            Image(systemName: "link")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.green)
          }
        }
        Text(device.encoding.rawValue.uppercased())
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Image(systemName: "chevron.right")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }
}

// MARK: - Command Row

private struct CommandRow: View {
  let command: CommandItem

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text(command.name)
          .font(.headline)
        Text(command.payload.prefix(60).appending(command.payload.count > 60 ? "..." : ""))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 3) {
        Text(command.payloadKind.rawValue.uppercased())
          .font(.caption.weight(.semibold))
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(.purple.opacity(0.12), in: Capsule())
          .foregroundStyle(.purple)
        Text("\(command.timeoutMs) ms")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      Image(systemName: "chevron.right")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }
}

// MARK: - Device Form Sheet

private struct DeviceFormSheet: View {
  @Environment(\.dismiss) private var dismiss

  @State private var device: DeviceItem
  private let onSave: (DeviceItem) -> Void
  private let isNew: Bool

  init(existing: DeviceItem?, onSave: @escaping (DeviceItem) -> Void) {
    self._device = State(initialValue: existing ?? DeviceItem(name: "", host: "", port: 23))
    self.onSave = onSave
    self.isNew = existing == nil
  }

  @State private var nameError = false
  @State private var hostError = false

  var body: some View {
    NavigationStack {
      Form {
        Section("Device Info") {
          TextField("Device Name", text: $device.name)
            .overlay(alignment: .trailing) {
              if nameError {
                Image(systemName: "exclamationmark.circle.fill")
                  .foregroundStyle(.red)
                  .padding(.trailing, 4)
              }
            }

          TextField("IP Address / Hostname", text: $device.host)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .overlay(alignment: .trailing) {
              if hostError {
                Image(systemName: "exclamationmark.circle.fill")
                  .foregroundStyle(.red)
                  .padding(.trailing, 4)
              }
            }

          TextField("Port", value: $device.port, format: .number)
            .keyboardType(.numberPad)
        }

        Section("Protocol & Encoding") {
          Picker("Transport", selection: $device.transport) {
            ForEach(TransportKind.allCases) { kind in
              Text(kind.rawValue.uppercased()).tag(kind)
            }
          }

          Picker("Encoding", selection: $device.encoding) {
            Text("UTF-8").tag(TextEncodingKind.utf8)
            Text("GB18030 (Legacy)").tag(TextEncodingKind.gb18030)
          }

          Text(encodingHint)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section("Connection") {
          Toggle("Keep Alive", isOn: $device.keepAlive)

          Text(device.keepAlive
            ? "TCP connection stays open and is reused across commands. Faster for devices that support persistent connections."
            : "A new TCP connection is created for each command and closed immediately after. Use this for devices that close the connection after responding."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
      .navigationTitle(isNew ? "Add Device" : "Edit Device")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { attemptSave() }
            .fontWeight(.semibold)
        }
      }
    }
    .presentationDetents([.medium])
    .presentationDragIndicator(.visible)
  }

  private var encodingHint: String {
    switch device.encoding {
    case .utf8:
      return "UTF-8 is suitable for modern network devices and supports all languages."
    case .gb18030:
      return "GB18030 is for legacy AV equipment (matrix switchers, amplifiers, etc.)."
    }
  }

  private func attemptSave() {
    nameError = device.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    hostError = device.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard !nameError, !hostError else { return }
    guard (1...65535).contains(device.port) else { return }
    onSave(device)
    dismiss()
  }
}

// MARK: - Command Form Sheet

private struct CommandFormSheet: View {
  @Environment(\.dismiss) private var dismiss

  @State private var command: CommandItem
  private let onSave: (CommandItem) -> Void
  private let isNew: Bool

  init(existing: CommandItem?, onSave: @escaping (CommandItem) -> Void) {
    self._command = State(
      initialValue: existing ?? CommandItem(name: "", payloadKind: .text, payload: ""))
    self.onSave = onSave
    self.isNew = existing == nil
  }

  @State private var nameError = false
  @State private var payloadError = false

  var body: some View {
    NavigationStack {
      Form {
        Section("Command Info") {
          TextField("Command Name", text: $command.name)
            .overlay(alignment: .trailing) {
              if nameError {
                Image(systemName: "exclamationmark.circle.fill")
                  .foregroundStyle(.red)
                  .padding(.trailing, 4)
              }
            }

          Picker("Payload Type", selection: $command.payloadKind) {
            Text("Text").tag(PayloadKind.text)
            Text("Hex").tag(PayloadKind.hex)
          }
          .pickerStyle(.segmented)
        }

        Section {
          TextField("Payload", text: $command.payload, axis: .vertical)
            .lineLimit(3...6)
            .font(.system(.body, design: .monospaced))
            .overlay(alignment: .topTrailing) {
              if payloadError {
                Image(systemName: "exclamationmark.circle.fill")
                  .foregroundStyle(.red)
                  .padding(4)
              }
            }

          Text(payloadHint)
            .font(.caption)
            .foregroundStyle(.secondary)
        } header: {
          Text("Payload Content")
        }

        Section("Line Ending") {
          Picker("Line Ending", selection: $command.lineEnding) {
            ForEach(LineEnding.allCases) { ending in
              Text(ending.displayName).tag(ending)
            }
          }
          Text("Appended automatically after each text command. Most AV devices require \\r\\n (CRLF).")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section("Timeout") {
          Stepper(
            "\(command.timeoutMs) ms",
            value: $command.timeoutMs,
            in: 100...10000,
            step: 100
          )
          Text("Recommended 1000-3000 ms. Maximum wait time for device response.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .navigationTitle(isNew ? "Add Command" : "Edit Command")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { attemptSave() }
            .fontWeight(.semibold)
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  private var payloadHint: String {
    switch command.payloadKind {
    case .text:
      return "Example: MATRIX ROUTE 1 2\\r\\n (\\r\\n = carriage return + line feed, auto-escaped)"
    case .hex:
      return "Example: FF 01 03 0A 00 (hex bytes separated by spaces)"
    }
  }

  private func attemptSave() {
    nameError = command.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    payloadError = command.payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard !nameError, !payloadError else { return }
    guard command.timeoutMs > 0 else { return }
    onSave(command)
    dismiss()
  }
}
