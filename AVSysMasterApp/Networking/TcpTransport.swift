import Combine
import Foundation
import Network

enum TcpTransportError: Error, LocalizedError {
  case invalidPort
  case invalidHex
  case invalidEncoding
  case timeout
  case sendFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidPort: return "Invalid port"
    case .invalidHex: return "Invalid hex payload"
    case .invalidEncoding: return "Invalid text encoding"
    case .timeout: return "Timeout"
    case let .sendFailed(msg): return msg
    }
  }
}

@MainActor
final class TcpTransport: ObservableObject {
  private let queue = DispatchQueue(label: "avsysmaster.tcp")

  /// Idle timeout before a persistent connection is automatically closed (seconds).
  private let idleTimeoutSec: TimeInterval = 120

  /// Hard timeout for TCP connect phase — prevents waiting for OS-level timeout (~75s).
  private let connectTimeoutSec: TimeInterval = 3

  // MARK: - Connection Pool

  private struct PoolKey: Hashable {
    let host: String
    let port: UInt16
  }

  private struct PoolEntry {
    let connection: NWConnection
    var idleTimer: Timer?
  }

  private var pool: [PoolKey: PoolEntry] = [:]

  // MARK: - Receive Support

  /// Publishes text received from pooled connections. Emitted on the main thread.
  let receivedData = PassthroughSubject<(host: String, port: UInt16, text: String), Never>()

  /// Publishes the raw payload string each time a command is successfully sent.
  /// Used by CommandTriggerEngine to match outgoing commands.
  let sentData = PassthroughSubject<(host: String, port: UInt16, payload: String), Never>()

  /// Tracks which pool keys already have a receive loop running.
  private var receiveLoopKeys: Set<PoolKey> = []

  /// Per-connection line buffer for reassembling partial lines across TCP packets.
  private var receiveLineBuffers: [PoolKey: String] = [:]

  // MARK: - Public API

  /// Ensure a persistent pooled connection exists for a device, creating one if needed.
  /// Used by HPDMonitor to start listening before any command is sent.
  func ensureConnection(device: DeviceItem) async throws {
    guard device.keepAlive else { return }
    guard let nwPort = NWEndpoint.Port(rawValue: UInt16(device.port)) else {
      throw TcpTransportError.invalidPort
    }
    let key = PoolKey(host: device.host, port: nwPort.rawValue)
    _ = try await readyConnection(for: key, device: device, nwPort: nwPort)
  }

  func sendRaw(
    device: DeviceItem, payload: String,
    lineEnding: LineEnding = .crlf, timeoutMs: Int = 1500
  ) async throws {
    print("[TCP] sendRaw → \(device.host):\(device.port)  payload=\"\(payload)\"  lineEnding=\(lineEnding.rawValue)  timeout=\(timeoutMs)ms  keepAlive=\(device.keepAlive)")
    guard let nwPort = NWEndpoint.Port(rawValue: UInt16(device.port)) else {
      print("[TCP] ❌ Invalid port: \(device.port)")
      throw TcpTransportError.invalidPort
    }
    guard var data = payload.data(using: device.encoding == .utf8 ? .utf8 : .init(
      rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
      )
    )) else {
      print("[TCP] ❌ Encoding failed (\(device.encoding.rawValue))")
      throw TcpTransportError.invalidEncoding
    }
    data.append(lineEnding.bytes)
    print("[TCP] Data ready: \(data.count) bytes")

    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          try await self.sendData(data, device: device, nwPort: nwPort)
        }
        group.addTask {
          try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
          throw TcpTransportError.timeout
        }
        _ = try await group.next()
        group.cancelAll()
      }
      print("[TCP] ✅ Sent successfully to \(device.host):\(device.port)")
      sentData.send((host: device.host, port: UInt16(device.port), payload: payload))
    } catch {
      print("[TCP] ❌ Failed: \(error.localizedDescription)")
      throw error
    }
  }

  func send(device: DeviceItem, command: CommandItem) async throws {
    guard let nwPort = NWEndpoint.Port(rawValue: UInt16(device.port)) else {
      throw TcpTransportError.invalidPort
    }
    let data = try payloadData(command: command, encoding: device.encoding)
    let timeout = command.timeoutMs

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await self.sendData(data, device: device, nwPort: nwPort)
      }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000)
        throw TcpTransportError.timeout
      }
      _ = try await group.next()
      group.cancelAll()
    }
    sentData.send((host: device.host, port: UInt16(device.port), payload: command.payload))
  }

  // MARK: - Retry Wrappers

  /// Wraps `send()` with automatic retry for transient errors (timeout, sendFailed).
  /// Returns the number of retries attempted (0 = succeeded on first try).
  private static let retryDelaysMs: [UInt64] = [500, 1000]

  @discardableResult
  func sendWithRetry(
    device: DeviceItem, command: CommandItem, maxRetries: Int = 2
  ) async throws -> Int {
    var lastError: Error?
    for attempt in 0...maxRetries {
      do {
        try await send(device: device, command: command)
        if attempt > 0 {
          print("[TCP] ✅ Retry succeeded on attempt \(attempt + 1) for \(device.host):\(device.port)")
        }
        return attempt
      } catch {
        lastError = error
        guard isRetryable(error), attempt < maxRetries else { break }
        let delayMs = Self.retryDelaysMs[min(attempt, Self.retryDelaysMs.count - 1)]
        print("[TCP] ⚠️ Attempt \(attempt + 1) failed for \(device.host):\(device.port), retrying in \(delayMs)ms…")
        evictIfNeeded(device: device)
        try await Task.sleep(nanoseconds: delayMs * 1_000_000)
      }
    }
    throw lastError!
  }

  /// Wraps `sendRaw()` with automatic retry for transient errors.
  @discardableResult
  func sendRawWithRetry(
    device: DeviceItem, payload: String,
    lineEnding: LineEnding = .crlf, timeoutMs: Int = 1500,
    maxRetries: Int = 2
  ) async throws -> Int {
    var lastError: Error?
    for attempt in 0...maxRetries {
      do {
        try await sendRaw(device: device, payload: payload, lineEnding: lineEnding, timeoutMs: timeoutMs)
        if attempt > 0 {
          print("[TCP] ✅ Retry succeeded on attempt \(attempt + 1) for \(device.host):\(device.port)")
        }
        return attempt
      } catch {
        lastError = error
        guard isRetryable(error), attempt < maxRetries else { break }
        let delayMs = Self.retryDelaysMs[min(attempt, Self.retryDelaysMs.count - 1)]
        print("[TCP] ⚠️ Attempt \(attempt + 1) failed for \(device.host):\(device.port), retrying in \(delayMs)ms…")
        evictIfNeeded(device: device)
        try await Task.sleep(nanoseconds: delayMs * 1_000_000)
      }
    }
    throw lastError!
  }

  private func isRetryable(_ error: Error) -> Bool {
    guard let tcpErr = error as? TcpTransportError else { return true }
    switch tcpErr {
    case .timeout, .sendFailed: return true
    case .invalidPort, .invalidHex, .invalidEncoding: return false
    }
  }

  private func evictIfNeeded(device: DeviceItem) {
    guard device.keepAlive, let nwPort = UInt16(exactly: device.port) else { return }
    evict(key: PoolKey(host: device.host, port: nwPort))
  }

  /// Disconnect all persistent connections (e.g. when app goes to background).
  func disconnectAll() {
    for (key, entry) in pool {
      entry.idleTimer?.invalidate()
      entry.connection.cancel()
      print("[TCP] Pool: closed persistent connection to \(key.host):\(key.port)")
    }
    pool.removeAll()
    receiveLoopKeys.removeAll()
    receiveLineBuffers.removeAll()
  }

  /// Disconnect a specific device's persistent connection.
  func disconnect(host: String, port: Int) {
    guard let nwPort = UInt16(exactly: port) else { return }
    let key = PoolKey(host: host, port: nwPort)
    if let entry = pool.removeValue(forKey: key) {
      entry.idleTimer?.invalidate()
      entry.connection.cancel()
      print("[TCP] Pool: closed persistent connection to \(host):\(port)")
    }
  }

  // MARK: - Core Send Logic

  private func sendData(_ data: Data, device: DeviceItem, nwPort: NWEndpoint.Port) async throws {
    if device.keepAlive {
      try await sendThroughPool(data: data, device: device, nwPort: nwPort)
    } else {
      let connection = NWConnection(
        host: NWEndpoint.Host(device.host), port: nwPort, using: .tcp
      )
      try await sendOneShot(connection: connection, data: data)
    }
  }

  // MARK: - One-Shot (legacy behaviour, keepAlive = false)

  private func sendOneShot(connection: NWConnection, data: Data) async throws {
    let deadline = DispatchWorkItem { connection.cancel() }
    DispatchQueue.main.asyncAfter(deadline: .now() + connectTimeoutSec, execute: deadline)

    defer { deadline.cancel() }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      nonisolated(unsafe) var done = false
      let finish: @Sendable (Result<Void, Error>) -> Void = { result in
        guard !done else { return }
        done = true
        connection.cancel()
        continuation.resume(with: result)
      }
      connection.stateUpdateHandler = { state in
        print("[TCP] OneShot state → \(state)")
        switch state {
        case .ready:
          connection.send(content: data, completion: .contentProcessed { error in
            if let error {
              finish(.failure(TcpTransportError.sendFailed(error.localizedDescription)))
            } else {
              finish(.success(()))
            }
          })
        case let .waiting(err):
          finish(.failure(TcpTransportError.sendFailed("Network unreachable: \(err.localizedDescription). Check local network permission in Settings.")))
        case let .failed(err):
          finish(.failure(TcpTransportError.sendFailed(err.localizedDescription)))
        case .cancelled:
          finish(.failure(TcpTransportError.timeout))
        default:
          break
        }
      }
      connection.start(queue: queue)
    }
  }

  // MARK: - Persistent Pool (keepAlive = true)

  private func sendThroughPool(data: Data, device: DeviceItem, nwPort: NWEndpoint.Port) async throws {
    let key = PoolKey(host: device.host, port: nwPort.rawValue)
    let conn = try await readyConnection(for: key, device: device, nwPort: nwPort)

    resetIdleTimer(for: key)

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      conn.send(content: data, completion: .contentProcessed { [weak self] error in
        if let error {
          print("[TCP] Pool: send failed on persistent connection → \(error.localizedDescription)")
          Task { @MainActor in self?.evict(key: key) }
          continuation.resume(throwing: TcpTransportError.sendFailed(error.localizedDescription))
        } else {
          print("[TCP] Pool: ✅ sent via persistent connection to \(key.host):\(key.port)")
          continuation.resume()
        }
      })
    }
  }

  /// Returns a `.ready` connection from the pool, or creates a new one.
  private func readyConnection(for key: PoolKey, device: DeviceItem, nwPort: NWEndpoint.Port) async throws -> NWConnection {
    if let entry = pool[key], entry.connection.state == .ready {
      print("[TCP] Pool: reusing connection to \(key.host):\(key.port)")
      return entry.connection
    }

    evict(key: key)

    print("[TCP] Pool: creating new persistent connection to \(key.host):\(key.port)")
    let tcp = NWProtocolTCP.Options()
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 10
    let params = NWParameters(tls: nil, tcp: tcp)
    let connection = NWConnection(
      host: NWEndpoint.Host(device.host), port: nwPort, using: params
    )

    try await waitForReady(connection: connection, key: key)
    pool[key] = PoolEntry(connection: connection, idleTimer: nil)
    startIdleTimer(for: key)
    monitorDisconnection(connection: connection, key: key)
    startReceiveLoop(connection: connection, key: key)
    return connection
  }

  /// Blocks until the connection reaches `.ready` or throws on failure.
  /// Enforces a hard connect timeout to avoid waiting for OS-level TCP timeout.
  private func waitForReady(connection: NWConnection, key: PoolKey) async throws {
    let deadline = DispatchWorkItem { connection.cancel() }
    DispatchQueue.main.asyncAfter(deadline: .now() + connectTimeoutSec, execute: deadline)

    defer { deadline.cancel() }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      nonisolated(unsafe) var done = false
      let finish: @Sendable (Result<Void, Error>) -> Void = { result in
        guard !done else { return }
        done = true
        continuation.resume(with: result)
      }
      connection.stateUpdateHandler = { state in
        print("[TCP] Pool: [\(key.host):\(key.port)] state → \(state)")
        switch state {
        case .ready:
          finish(.success(()))
        case let .waiting(err):
          connection.cancel()
          finish(.failure(TcpTransportError.sendFailed("Network unreachable: \(err.localizedDescription). Check local network permission in Settings.")))
        case let .failed(err):
          finish(.failure(TcpTransportError.sendFailed(err.localizedDescription)))
        case .cancelled:
          finish(.failure(TcpTransportError.timeout))
        default:
          break
        }
      }
      connection.start(queue: queue)
    }
  }

  /// Watches a pooled connection for unexpected disconnection and auto-evicts.
  private func monitorDisconnection(connection: NWConnection, key: PoolKey) {
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .failed, .cancelled:
        print("[TCP] Pool: connection to \(key.host):\(key.port) lost → evicting")
        Task { @MainActor in
          self?.receiveLoopKeys.remove(key)
          self?.receiveLineBuffers.removeValue(forKey: key)
          self?.evict(key: key)
        }
      default:
        break
      }
    }
  }

  // MARK: - Receive Loop

  /// Starts a continuous receive loop on a pooled connection, publishing each
  /// complete line (delimited by \r\n or \n) via `receivedData`.
  private func startReceiveLoop(connection: NWConnection, key: PoolKey) {
    guard !receiveLoopKeys.contains(key) else { return }
    receiveLoopKeys.insert(key)
    receiveLineBuffers[key] = ""
    scheduleReceive(connection: connection, key: key)
  }

  private func scheduleReceive(connection: NWConnection, key: PoolKey) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if let data, let chunk = String(data: data, encoding: .utf8) {
          var buf = (self.receiveLineBuffers[key] ?? "") + chunk
          while let range = buf.rangeOfCharacter(from: .newlines) {
            let line = String(buf[buf.startIndex..<range.lowerBound])
            buf = String(buf[range.upperBound...])
            if !line.isEmpty {
              self.receivedData.send((host: key.host, port: key.port, text: line))
            }
          }
          self.receiveLineBuffers[key] = buf
        }
        if error != nil || isComplete {
          self.receiveLoopKeys.remove(key)
          self.receiveLineBuffers.removeValue(forKey: key)
          return
        }
        self.scheduleReceive(connection: connection, key: key)
      }
    }
  }

  // MARK: - Idle Timer

  private func startIdleTimer(for key: PoolKey) {
    let timer = Timer.scheduledTimer(withTimeInterval: idleTimeoutSec, repeats: false) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        print("[TCP] Pool: idle timeout → closing \(key.host):\(key.port)")
        self.evict(key: key)
      }
    }
    pool[key]?.idleTimer = timer
  }

  private func resetIdleTimer(for key: PoolKey) {
    pool[key]?.idleTimer?.invalidate()
    startIdleTimer(for: key)
  }

  private func evict(key: PoolKey) {
    if let entry = pool.removeValue(forKey: key) {
      entry.idleTimer?.invalidate()
      entry.connection.cancel()
    }
  }

  // MARK: - Payload Encoding

  private func payloadData(command: CommandItem, encoding: TextEncodingKind) throws -> Data {
    switch command.payloadKind {
    case .text:
      var data: Data
      switch encoding {
      case .utf8:
        guard let encoded = command.payload.data(using: .utf8) else {
          throw TcpTransportError.invalidEncoding
        }
        data = encoded
      case .gb18030:
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(
          CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        guard let encoded = command.payload.data(using: .init(rawValue: nsEncoding)) else {
          throw TcpTransportError.invalidEncoding
        }
        data = encoded
      }
      data.append(command.lineEnding.bytes)
      return data
    case .hex:
      guard let data = Data(hexString: command.payload) else {
        throw TcpTransportError.invalidHex
      }
      return data
    }
  }
}

private extension Data {
  init?(hexString: String) {
    let cleaned = hexString.replacingOccurrences(of: " ", with: "")
      .replacingOccurrences(of: "\n", with: "")
    guard cleaned.count % 2 == 0 else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(cleaned.count / 2)
    var index = cleaned.startIndex
    while index < cleaned.endIndex {
      let next = cleaned.index(index, offsetBy: 2)
      guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    self = Data(bytes)
  }
}
