import Combine
import Foundation

/// Builds HTTP MJPEG stream URLs for LiveMatrix controls.
enum LiveMatrixStreamURL {
  static func build(
    customFields: [String: String],
    ip: String,
    port: String,
    devID: String
  ) -> URL? {
    let host = customFields["liveMatrixStreamServerHost"] ?? ""
    let serverPort = customFields["liveMatrixStreamServerPort"] ?? ""
    guard !host.isEmpty, !serverPort.isEmpty, !ip.isEmpty else { return nil }
    var components = URLComponents()
    components.scheme = "http"
    components.host = host
    components.port = Int(serverPort)
    components.path = "/"
    components.queryItems = [
      URLQueryItem(name: "action", value: "stream"),
      URLQueryItem(name: "w", value: customFields["liveMatrixStreamWidth"] ?? "960"),
      URLQueryItem(name: "h", value: customFields["liveMatrixStreamHeight"] ?? "540"),
      URLQueryItem(name: "fps", value: customFields["liveMatrixStreamFps"] ?? "30"),
      URLQueryItem(name: "bw", value: customFields["liveMatrixStreamBw"] ?? "8000"),
      URLQueryItem(name: "as", value: customFields["liveMatrixStreamAs"] ?? "0"),
      URLQueryItem(name: "dev", value: devID),
      URLQueryItem(name: "ip", value: ip),
      URLQueryItem(name: "port", value: port.isEmpty ? "8080" : port),
    ]
    return components.url
  }
}

// MARK: - Device list discovery (`config get devicelist`)

enum MatrixDeviceRole: Equatable {
  case encoder
  case decoder
}

struct MatrixDiscoveredDevice: Identifiable, Equatable {
  let id: String
  let mac: String
  let ip: String
  let role: MatrixDeviceRole
}

struct MatrixDeviceInfoResponse: Equatable {
  let mac: String
  let ip: String
  let port: String?
}

enum MatrixDeviceListParser {
  /// Parses `config get devicelist` JSON: `{"info":{"Show-TV":{"mac":"...","ip":"...","id":"Show-TV"},...}}`
  static func parse(_ text: String) -> [MatrixDiscoveredDevice]? {
    guard let json = extractJSONPayload(from: text),
          let data = json.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let info = root["info"] as? [String: Any]
    else { return nil }

    var devices: [MatrixDiscoveredDevice] = []
    for (key, value) in info {
      guard let entry = value as? [String: Any],
            let mac = entry["mac"] as? String,
            let ip = entry["ip"] as? String,
            !mac.isEmpty, !ip.isEmpty,
            let role = role(of: entry)
      else { continue }
      let deviceID = (entry["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key
      devices.append(MatrixDiscoveredDevice(id: deviceID, mac: mac, ip: ip, role: role))
    }
    guard !devices.isEmpty else { return nil }
    return devices.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
  }

  /// Encoders (`is_host`) vs decoders (displays); skips entries that cannot be classified.
  static func role(of entry: [String: Any]) -> MatrixDeviceRole? {
    if isHostDevice(entry) { return .encoder }
    if entry["video"] != nil { return .decoder }
    if let model = entry["modelname"] as? String {
      let upper = model.uppercased()
      if upper.contains("EV2") || upper.contains("-EV") { return .encoder }
      if upper.contains("DV2") || upper.contains("-DV") { return .decoder }
    }
    if entry["edid"] != nil { return .encoder }
    return .decoder
  }

  private static func isHostDevice(_ entry: [String: Any]) -> Bool {
    switch entry["is_host"] {
    case let n as Int: return n == 1
    case let n as NSNumber: return n.intValue == 1
    case let s as String: return s == "1" || s.lowercased() == "true"
    case let b as Bool: return b
    default: return false
    }
  }

  /// Parses `config get device info {id}` JSON: `{"info":{"mac":"...","ip":"...","port":"..."}}`
  static func parseDeviceInfo(_ text: String) -> MatrixDeviceInfoResponse? {
    guard let json = extractJSONPayload(from: text),
          let data = json.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let info = root["info"] as? [String: Any],
          let mac = info["mac"] as? String,
          let ip = info["ip"] as? String,
          !mac.isEmpty, !ip.isEmpty
    else { return nil }
    let port = (info["port"] as? String) ?? (info["port"] as? Int).map { String($0) }
    return MatrixDeviceInfoResponse(mac: mac, ip: ip, port: port)
  }

  /// Strips log prefixes (e.g. `Response: {...}`) and returns the JSON substring.
  static func extractJSONPayload(from line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let start = trimmed.firstIndex(of: "{") else { return nil }
    return String(trimmed[start...])
  }
}

enum MatrixDeviceQueryClient {
  /// Opens a persistent connection, sends `payload`, and returns the first received line within `timeout`.
  @MainActor
  static func query(
    transport: TcpTransport,
    device: DeviceItem,
    payload: String,
    timeout: TimeInterval = 4
  ) async throws -> String {
    try await transport.ensureConnection(device: device)

    let host = device.host
    let port = device.port
    var streamContinuation: AsyncStream<String>.Continuation?
    let responseStream = AsyncStream<String> { continuation in
      streamContinuation = continuation
    }
    var cancellable: AnyCancellable?
    cancellable = transport.receivedData
      .filter { $0.host == host && Int($0.port) == port }
      .map { $0.text }
      .sink { line in
        streamContinuation?.yield(line)
        _ = cancellable
      }

    defer { cancellable?.cancel() }

    try await transport.sendRaw(
      device: device,
      payload: payload,
      lineEnding: .crlf,
      timeoutMs: 2000
    )

    let deadline = Date().addingTimeInterval(timeout)
    for await line in responseStream {
      if MatrixDeviceListParser.extractJSONPayload(from: line) != nil {
        return line
      }
      if Date() >= deadline { break }
    }
    throw MatrixDeviceQueryError.timeout
  }
}

enum MatrixDeviceQueryError: LocalizedError {
  case timeout
  case noDeviceBound
  case keepAliveRequired

  var errorDescription: String? {
    switch self {
    case .timeout:
      return "Timeout — no response"
    case .noDeviceBound:
      return "No device bound"
    case .keepAliveRequired:
      return "Device must enable Keep-Alive"
    }
  }
}
