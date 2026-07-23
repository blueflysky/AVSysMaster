import Foundation
import UIKit

enum VisualState: Equatable {
  case idle
  case busy
  case active
  case error
}

@MainActor
final class RuntimeControlStore: ObservableObject {
  @Published private(set) var states: [UUID: VisualState] = [:]

  /// Live/matrix output → input route map. Key: `"\(parentControlID):\(outputIndex)"`.
  @Published private(set) var matrixOutputRoutes: [String: Int] = [:]

  private var errorResetTasks: [UUID: Task<Void, Never>] = [:]

  private func matrixRouteKey(parentID: UUID, outputIndex: Int) -> String {
    "\(parentID.uuidString):\(outputIndex)"
  }

  func routedInput(parentID: UUID, outputIndex: Int) -> Int? {
    matrixOutputRoutes[matrixRouteKey(parentID: parentID, outputIndex: outputIndex)]
  }

  func setRoutedInput(_ input: Int, parentID: UUID, outputIndex: Int) {
    let key = matrixRouteKey(parentID: parentID, outputIndex: outputIndex)
    var routes = matrixOutputRoutes
    routes[key] = input
    matrixOutputRoutes = routes
  }

  func clearRoutedInput(parentID: UUID, outputIndex: Int) {
    let key = matrixRouteKey(parentID: parentID, outputIndex: outputIndex)
    var routes = matrixOutputRoutes
    routes.removeValue(forKey: key)
    matrixOutputRoutes = routes
  }

  func allRoutes(parentID: UUID, outputCount: Int) -> [Int: Int] {
    var result: [Int: Int] = [:]
    for o in 0..<outputCount {
      if let inp = routedInput(parentID: parentID, outputIndex: o) {
        result[o] = inp
      }
    }
    return result
  }

  /// Returns persisted routes, or a 1:1 input→output preview map when none are stored.
  func resolvedRoutes(parentID: UUID, inputCount: Int, outputCount: Int) -> [Int: Int] {
    let stored = allRoutes(parentID: parentID, outputCount: outputCount)
    if !stored.isEmpty { return stored }
    var defaults: [Int: Int] = [:]
    for i in 0..<min(inputCount, outputCount) {
      defaults[i] = i
    }
    return defaults
  }

  func state(for id: UUID) -> VisualState {
    states[id] ?? .idle
  }

  func markBusy(_ id: UUID) {
    cancelErrorReset(id)
    states[id] = .busy
  }

  func markActive(_ id: UUID) {
    cancelErrorReset(id)
    states[id] = .active
  }

  func markError(_ id: UUID) {
    states[id] = .error
    scheduleErrorReset(id, after: 2.0)
  }

  func markIdle(_ id: UUID) {
    cancelErrorReset(id)
    states[id] = .idle
  }

  func applyBehavior(control: ControlItem, allControls: [ControlItem]) {
    switch control.behavior {
    case .momentary:
      states[control.id] = .active
      Task {
        try? await Task.sleep(nanoseconds: 350_000_000)
        await MainActor.run {
          self.states[control.id] = .idle
        }
      }
    case .toggle:
      states[control.id] = (states[control.id] == .active) ? .idle : .active
    case .radio:
      if let key = control.groupKey {
        for item in allControls where item.groupKey == key {
          states[item.id] = item.id == control.id ? .active : .idle
        }
      } else {
        states[control.id] = .active
      }
    }
    triggerHaptic(.medium)
  }

  func triggerHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
    let generator = UIImpactFeedbackGenerator(style: style)
    generator.impactOccurred()
  }

  func triggerErrorHaptic() {
    let generator = UINotificationFeedbackGenerator()
    generator.notificationOccurred(.error)
  }

  // MARK: - Error Auto-Reset

  private func scheduleErrorReset(_ id: UUID, after seconds: Double) {
    cancelErrorReset(id)
    errorResetTasks[id] = Task {
      try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        if self.states[id] == .error {
          self.states[id] = .idle
        }
        self.errorResetTasks[id] = nil
      }
    }
  }

  private func cancelErrorReset(_ id: UUID) {
    errorResetTasks[id]?.cancel()
    errorResetTasks[id] = nil
  }
}
