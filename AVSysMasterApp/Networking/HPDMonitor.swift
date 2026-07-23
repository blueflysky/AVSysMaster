import Combine
import Foundation

/// Monitors HPD (Hot Plug Detect) messages from a matrix device over TCP.
///
/// The device pushes lines like `188A6A012FAF:IN1 HPD 1` (signal present) or
/// `188A6A012FAF:IN1 HPD 0` (signal lost) on the same keepAlive connection
/// used for sending commands. This class subscribes to `TcpTransport.receivedData`,
/// filters by the target device, parses HPD messages, and publishes per-devID
/// signal state for the UI to react to.
@MainActor
final class HPDMonitor: ObservableObject {

  /// Per-devID signal presence. `true` = signal present (HPD 1),
  /// `false` = signal lost (HPD 0). A devID absent from the dictionary
  /// means no HPD message has been received yet — treat as "unknown / normal".
  @Published var signalState: [String: Bool] = [:]

  private var cancellable: AnyCancellable?
  private var monitoredHost: String?
  private var monitoredPort: UInt16?

  // MARK: - Lifecycle

  /// Begin monitoring HPD messages for `device`. Ensures a TCP connection
  /// exists (even before any command is sent) and subscribes to incoming lines.
  func start(transport: TcpTransport, device: DeviceItem) {
    stop()
    guard device.keepAlive else { return }

    monitoredHost = device.host
    monitoredPort = UInt16(device.port)

    cancellable = transport.receivedData
      .filter { [weak self] host, port, _ in
        host == self?.monitoredHost && port == self?.monitoredPort
      }
      .sink { [weak self] _, _, text in
        self?.processLine(text)
      }

    Task {
      do {
        try await transport.ensureConnection(device: device)
        print("[HPD] Monitoring started for \(device.host):\(device.port)")
      } catch {
        print("[HPD] Failed to ensure connection: \(error.localizedDescription)")
      }
    }
  }

  func stop() {
    cancellable?.cancel()
    cancellable = nil
    signalState.removeAll()
    monitoredHost = nil
    monitoredPort = nil
  }

  /// Re-establish the TCP connection after the app returns to foreground.
  func reconnect(transport: TcpTransport, device: DeviceItem) {
    guard monitoredHost != nil else { return }
    Task {
      do {
        try await transport.ensureConnection(device: device)
        print("[HPD] Reconnected for \(device.host):\(device.port)")
      } catch {
        print("[HPD] Reconnect failed: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Parsing

  /// Matches lines like `188A6A012FAF:IN1 HPD 1` or `188A6A012FAF:IN1 HPD 0`.
  private static let hpdPattern = try! NSRegularExpression(
    pattern: #"^([A-Fa-f0-9]+):IN\d+\s+HPD\s+([01])"#
  )

  private func processLine(_ line: String) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    let nsRange = NSRange(trimmed.startIndex..., in: trimmed)
    guard let match = Self.hpdPattern.firstMatch(in: trimmed, range: nsRange),
          match.numberOfRanges >= 3,
          let devIDRange = Range(match.range(at: 1), in: trimmed),
          let hpdRange = Range(match.range(at: 2), in: trimmed)
    else { return }

    let devID = String(trimmed[devIDRange]).uppercased()
    let hasSignal = trimmed[hpdRange] == "1"

    if signalState[devID] != hasSignal {
      print("[HPD] \(devID) signal \(hasSignal ? "PRESENT" : "LOST")")
      signalState[devID] = hasSignal
    }
  }
}
