import Combine
import Foundation

/// Monitors both incoming TCP data and outgoing commands.
/// When a `CommandTriggerRule` matches, automatically sends the configured action command.
///
/// Usage: instantiate as `@StateObject` in `ControlPageView`, call `start(transport:model:)`
/// on appear and whenever `modelStore.runtime.triggerRules` changes.
@MainActor
final class CommandTriggerEngine: ObservableObject {

  private var incomingCancellable: AnyCancellable?
  private var outgoingCancellable: AnyCancellable?

  /// Per-rule last-fired timestamp for cooldown enforcement.
  private var lastFiredAt: [UUID: Date] = [:]

  // MARK: - Lifecycle

  func start(transport: TcpTransport, model: UnifiedControlModel) {
    stop()
    guard !model.triggerRules.filter(\.enabled).isEmpty else { return }

    incomingCancellable = transport.receivedData
      .sink { [weak self] host, port, text in
        self?.evaluate(
          source: .incoming, host: host, port: port,
          text: text, transport: transport, model: model
        )
      }

    outgoingCancellable = transport.sentData
      .sink { [weak self] host, port, payload in
        self?.evaluate(
          source: .outgoing, host: host, port: port,
          text: payload, transport: transport, model: model
        )
      }

    print("[Trigger] Engine started with \(model.triggerRules.filter(\.enabled).count) active rule(s)")
  }

  func stop() {
    incomingCancellable?.cancel()
    outgoingCancellable?.cancel()
    incomingCancellable = nil
    outgoingCancellable = nil
    lastFiredAt.removeAll()
    print("[Trigger] Engine stopped")
  }

  // MARK: - Evaluation

  private func evaluate(
    source: TriggerSource,
    host: String, port: UInt16,
    text: String,
    transport: TcpTransport,
    model: UnifiedControlModel
  ) {
    let now = Date()

    for rule in model.triggerRules where rule.enabled && rule.source == source {
      // 1. 设备过滤
      if let watchID = rule.watchDeviceID {
        guard let dev = model.devices.first(where: { $0.id == watchID }),
              dev.host == host, dev.port == Int(port)
        else { continue }
      }

      // 2. 模式匹配
      guard matches(text: text, rule: rule) else { continue }

      // 3. 冷却校验
      if let last = lastFiredAt[rule.id],
         now.timeIntervalSince(last) * 1000 < Double(rule.cooldownMs) {
        print("[Trigger] Rule '\(rule.name)' skipped (cooldown)")
        continue
      }
      lastFiredAt[rule.id] = now

      // 4. 触发
      fire(rule: rule, model: model, transport: transport)
    }
  }

  // MARK: - Matching

  private func matches(text: String, rule: CommandTriggerRule) -> Bool {
    let pattern = rule.pattern
    guard !pattern.isEmpty else { return false }

    switch rule.matchMode {
    case .contains:
      return text.localizedCaseInsensitiveContains(pattern)
    case .prefix:
      return text.lowercased().hasPrefix(pattern.lowercased())
    case .suffix:
      return text.lowercased().hasSuffix(pattern.lowercased())
    case .regex:
      guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
      else { return false }
      let range = NSRange(text.startIndex..., in: text)
      return regex.firstMatch(in: text, range: range) != nil
    }
  }

  // MARK: - Fire Actions

  private func fire(
    rule: CommandTriggerRule,
    model: UnifiedControlModel,
    transport: TcpTransport
  ) {
    guard !rule.actions.isEmpty else {
      print("[Trigger] Rule '\(rule.name)' fired but has no actions configured")
      return
    }

    Task {
      for action in rule.actions {
        guard
          let devID = action.deviceID,
          let cmdID = action.commandID,
          let device = model.devices.first(where: { $0.id == devID }),
          let command = model.commands.first(where: { $0.id == cmdID })
        else {
          print("[Trigger] Rule '\(rule.name)' skipping action — device/command not found")
          continue
        }

        if action.delayMs > 0 {
          try? await Task.sleep(nanoseconds: UInt64(action.delayMs) * 1_000_000)
        }

        do {
          print("[Trigger] Rule '\(rule.name)' → \(device.name) · \(command.name)")
          try await transport.sendWithRetry(device: device, command: command)
        } catch {
          print("[Trigger] Rule '\(rule.name)' action send failed: \(error.localizedDescription)")
        }
      }
    }
  }
}
