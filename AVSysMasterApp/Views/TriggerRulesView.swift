import SwiftUI

// MARK: - Trigger Rules List

struct TriggerRulesView: View {
  @EnvironmentObject private var modelStore: UnifiedModelStore
  @State private var editingRule: CommandTriggerRule?
  @State private var showAddSheet = false

  var body: some View {
    List {
      Section {
        ForEach($modelStore.draft.triggerRules) { $rule in
          TriggerRuleRow(rule: $rule) {
            editingRule = rule
          } onToggle: {
            Task { try? await modelStore.saveDraft() }
            _ = modelStore.publishDraft()
          }
        }
        .onDelete { indexSet in
          modelStore.draft.triggerRules.remove(atOffsets: indexSet)
          Task { try? await modelStore.saveDraft() }
          _ = modelStore.publishDraft()
        }
        .onMove { from, to in
          modelStore.draft.triggerRules.move(fromOffsets: from, toOffset: to)
        }

        Button {
          addRule()
        } label: {
          Label("添加规则", systemImage: "plus.circle")
        }
      } header: {
        HStack {
          Text("触发规则")
          Spacer()
          Button {
            addRule()
          } label: {
            Image(systemName: "plus")
              .font(.caption.weight(.semibold))
          }
          .buttonStyle(.plain)
          .foregroundStyle(Color.accentColor)
        }
      } footer: {
        if modelStore.draft.triggerRules.isEmpty {
          Text("监听指定报文并自动发送命令。左滑删除，长按拖动排序。")
        }
      }
    }
    .listStyle(.insetGrouped)
    .environment(\.editMode, .constant(.active))
    .navigationTitle("触发规则")
    .sheet(item: $editingRule) { rule in
      TriggerRuleEditorView(rule: rule) { updated in
        if let idx = modelStore.draft.triggerRules.firstIndex(where: { $0.id == updated.id }) {
          modelStore.draft.triggerRules[idx] = updated
        }
        Task { try? await modelStore.saveDraft() }
        _ = modelStore.publishDraft()
      }
    }
  }

  private func addRule() {
    let newRule = CommandTriggerRule()
    modelStore.draft.triggerRules.append(newRule)
    editingRule = newRule
  }
}

// MARK: - Rule Row

private struct TriggerRuleRow: View {
  @Binding var rule: CommandTriggerRule
  let onEdit: () -> Void
  let onToggle: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Toggle("", isOn: $rule.enabled)
        .labelsHidden()
        .onChange(of: rule.enabled) { onToggle() }

      VStack(alignment: .leading, spacing: 3) {
        Text(rule.name.isEmpty ? "未命名规则" : rule.name)
          .font(.body.weight(.medium))
          .foregroundStyle(rule.enabled ? .primary : .secondary)

        Text(ruleSummary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()

      Button {
        onEdit()
      } label: {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .buttonStyle(.plain)
    }
    .contentShape(Rectangle())
    .onTapGesture { onEdit() }
  }

  private var ruleSummary: String {
    let src = rule.source.displayName
    let mode = rule.matchMode.displayName
    let pat = rule.pattern.isEmpty ? "（未设置）" : "\"\(rule.pattern)\""
    let actionCount = rule.actions.count
    let actionStr = actionCount == 0 ? "无动作" : "\(actionCount) 条动作"
    return "\(src) · \(mode) \(pat) → \(actionStr)"
  }
}

// MARK: - Rule Editor

struct TriggerRuleEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var modelStore: UnifiedModelStore

  @State private var rule: CommandTriggerRule
  private let onSave: (CommandTriggerRule) -> Void

  init(rule: CommandTriggerRule, onSave: @escaping (CommandTriggerRule) -> Void) {
    self._rule = State(initialValue: rule)
    self.onSave = onSave
  }

  var body: some View {
    NavigationStack {
      Form {
        basicSection
        conditionSection
        actionSection
        advancedSection
      }
      .navigationTitle(rule.name.isEmpty ? "新规则" : rule.name)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存") {
            onSave(rule)
            dismiss()
          }
          .fontWeight(.semibold)
          .disabled(rule.pattern.isEmpty || rule.actions.isEmpty)
        }
      }
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
  }

  // MARK: - Sections

  private var basicSection: some View {
    Section("基本信息") {
      TextField("规则名称", text: $rule.name)
      Toggle("启用", isOn: $rule.enabled)
    }
  }

  private var conditionSection: some View {
    Section {
      Picker("监听方向", selection: $rule.source) {
        ForEach(TriggerSource.allCases) { src in
          Text(src.displayName).tag(src)
        }
      }

      // 监听设备
      Picker("监听设备", selection: $rule.watchDeviceID) {
        Text("所有设备").tag(Optional<UUID>.none)
        ForEach(modelStore.draft.devices) { dev in
          Text(dev.name).tag(Optional(dev.id))
        }
      }

      // 匹配模式
      Picker("匹配模式", selection: $rule.matchMode) {
        ForEach(TriggerMatchMode.allCases) { mode in
          Text(mode.displayName).tag(mode)
        }
      }

      // 匹配关键词
      VStack(alignment: .leading, spacing: 4) {
        TextField(
          rule.matchMode == .regex ? "正则表达式" : "匹配关键词",
          text: $rule.pattern
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()

        if rule.matchMode == .regex, !rule.pattern.isEmpty {
          let isValid = (try? NSRegularExpression(pattern: rule.pattern)) != nil
          Text(isValid ? "正则有效" : "正则语法错误")
            .font(.caption)
            .foregroundStyle(isValid ? .green : .red)
        }
      }
    } header: {
      Text("触发条件")
    } footer: {
      Text("匹配不区分大小写。正则模式支持完整 NSRegularExpression 语法。")
        .font(.caption)
    }
  }

  private var actionSection: some View {
    Section {
      ForEach($rule.actions) { $action in
        TriggerActionRow(action: $action)
      }
      .onDelete { indexSet in
        rule.actions.remove(atOffsets: indexSet)
      }
      .onMove { from, to in
        rule.actions.move(fromOffsets: from, toOffset: to)
      }

      Button {
        rule.actions.append(TriggerAction())
      } label: {
        Label("添加动作", systemImage: "plus.circle")
      }
    } header: {
      HStack {
        Text("触发动作")
        Spacer()
        Button {
          rule.actions.append(TriggerAction())
        } label: {
          Image(systemName: "plus")
            .font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
      }
    } footer: {
      Text("按顺序执行，左滑删除，长按拖动排序。")
        .font(.caption)
    }
  }

  private var advancedSection: some View {
    Section {
      Stepper(
        "冷却时间：\(rule.cooldownMs) ms",
        value: $rule.cooldownMs,
        in: 0...30000, step: 100
      )
    } header: {
      Text("高级设置")
    } footer: {
      Text("同一规则在冷却时间内只触发一次，防止重复发送。")
        .font(.caption)
    }
  }
}

// MARK: - Trigger Action Row

private struct TriggerActionRow: View {
  @Binding var action: TriggerAction
  @EnvironmentObject private var modelStore: UnifiedModelStore

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // 设备选择
      Picker("设备", selection: $action.deviceID) {
        Text("未选择设备").tag(Optional<UUID>.none)
        ForEach(modelStore.draft.devices) { dev in
          Text(dev.name).tag(Optional(dev.id))
        }
      }
      .onChange(of: action.deviceID) {
        action.commandID = nil
      }

      // 命令选择
      Picker("命令", selection: $action.commandID) {
        Text("未选择命令").tag(Optional<UUID>.none)
        ForEach(modelStore.draft.commands) { cmd in
          Text(cmd.name).tag(Optional(cmd.id))
        }
      }

      // 命令载荷预览
      if let cmdID = action.commandID,
         let cmd = modelStore.draft.commands.first(where: { $0.id == cmdID }) {
        Text(cmd.payload.isEmpty ? "（空载荷）" : cmd.payload)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      // 延迟设置
      Stepper(
        "延迟：\(action.delayMs) ms",
        value: $action.delayMs,
        in: 0...30000, step: 100
      )
      .font(.subheadline)
    }
    .padding(.vertical, 4)
  }
}
