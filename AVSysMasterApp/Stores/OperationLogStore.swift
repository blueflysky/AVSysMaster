import Foundation

enum LogResult: Equatable {
  case pending
  case success
  case failure(String)
}

struct LogEntry: Identifiable {
  let id = UUID()
  let timestamp: Date
  let controlTitle: String
  let commandName: String
  let payload: String
  let deviceName: String
  let deviceHost: String
  var result: LogResult = .pending

  var resultText: String {
    switch result {
    case .pending: return "Sending..."
    case .success: return "OK"
    case .failure(let msg): return "Error: \(msg)"
    }
  }
}

@MainActor
final class OperationLogStore: ObservableObject {
  static let shared = OperationLogStore()

  @Published private(set) var entries: [LogEntry] = []

  private let maxEntries = 200

  func append(
    controlTitle: String, commandName: String, payload: String,
    deviceName: String, deviceHost: String
  ) {
    let entry = LogEntry(
      timestamp: Date(),
      controlTitle: controlTitle,
      commandName: commandName,
      payload: payload,
      deviceName: deviceName,
      deviceHost: deviceHost
    )
    entries.insert(entry, at: 0)
    if entries.count > maxEntries {
      entries.removeLast(entries.count - maxEntries)
    }
  }

  func markLastResult(_ result: LogResult) {
    guard !entries.isEmpty else { return }
    entries[0].result = result
  }

  func clear() {
    entries.removeAll()
  }
}
