import Combine
import SwiftUI

// MARK: - MJPEGStreamHub

/// Manages a pool of MJPEG sessions keyed by URL.
/// Multiple views sharing the same stream URL will share a single HTTP connection.
final class MJPEGStreamHub: ObservableObject {
  private var sessions: [URL: MJPEGSession] = [:]

  func acquire(_ url: URL) -> MJPEGSession {
    if let existing = sessions[url] {
      existing.refCount += 1
      return existing
    }
    let session = MJPEGSession(url: url)
    sessions[url] = session
    session.start()
    return session
  }

  func release(_ url: URL) {
    guard let session = sessions[url] else { return }
    session.refCount -= 1
    if session.refCount <= 0 {
      DispatchQueue.main.async {
        session.latestFrame = nil
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
        guard let self, let s = self.sessions[url], s.refCount <= 0 else { return }
        s.stop()
        self.sessions.removeValue(forKey: url)
      }
    }
  }

  func refreshAll() {
    sessions.values.forEach { $0.reconnect() }
  }
}

// MARK: - MJPEGSession

/// A single MJPEG HTTP connection that decodes frames and publishes the latest one.
/// Uses JPEG SOI (0xFFD8) / EOI (0xFFD9) markers for boundary-agnostic frame slicing.
///
/// Thread model:
///   - `buffer` is only accessed on `delegateQueue` (serial OperationQueue used as
///     URLSession delegate queue). Cleared via `delegateQueue.addOperation` in `start()`.
///   - `lastFrameAt`, `retryDelay`, `isRetrying`, watchdog timer — main thread only.
///   - `latestFrame` (@Published) — set on main thread.
final class MJPEGSession: NSObject, ObservableObject {
  let url: URL
  var refCount = 1

  @Published var latestFrame: UIImage?

  private var urlSession: URLSession?
  private var dataTask: URLSessionDataTask?
  private var buffer = Data()
  private let decodeQueue = DispatchQueue(label: "mjpeg.decode", qos: .userInitiated)
  private let delegateQueue: OperationQueue = {
    let q = OperationQueue()
    q.maxConcurrentOperationCount = 1
    q.qualityOfService = .userInitiated
    return q
  }()

  private var retryDelay: TimeInterval = 1.0
  private var retryWorkItem: DispatchWorkItem?
  private var watchdogTimer: Timer?
  private var lastFrameAt: Date?
  private var isRetrying = false

  private static let jpegSOI = Data([0xFF, 0xD8])
  private static let jpegEOI = Data([0xFF, 0xD9])

  init(url: URL) {
    self.url = url
    super.init()
  }

  // MARK: - Lifecycle

  /// Full start: creates a new URLSession + DataTask, clears all state.
  func start() {
    stopWatchdog()
    retryWorkItem?.cancel()
    retryWorkItem = nil
    dataTask?.cancel()
    dataTask = nil
    urlSession?.invalidateAndCancel()

    retryDelay = 1.0
    isRetrying = false
    lastFrameAt = nil

    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 60 * 60
    urlSession = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)

    delegateQueue.addOperation { [weak self] in
      self?.buffer.removeAll()
    }

    let task = urlSession!.dataTask(with: url)
    dataTask = task
    task.resume()
    startWatchdog()
  }

  func stop() {
    stopWatchdog()
    retryWorkItem?.cancel()
    retryWorkItem = nil
    dataTask?.cancel()
    dataTask = nil
    urlSession?.invalidateAndCancel()
    urlSession = nil
  }

  /// Called from outside (e.g. app wake / refreshAll). Full restart.
  func reconnect() {
    start()
  }

  /// Lightweight reconnect: reuses the existing URLSession, only recreates DataTask.
  /// Buffer is not cleared — the SOI/EOI parser skips stale partial data.
  private func reconnectTask() {
    isRetrying = false
    dataTask?.cancel()

    guard let session = urlSession else {
      start()
      return
    }

    let task = session.dataTask(with: url)
    dataTask = task
    task.resume()
  }

  // MARK: - Watchdog (main-thread timer, conditional reconnect)

  private func startWatchdog() {
    stopWatchdog()
    watchdogTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
      guard let self else { return }
      if self.isRetrying { return }
      let stale = self.lastFrameAt.map { Date().timeIntervalSince($0) > 8 } ?? true
      if stale { self.reconnectTask() }
    }
  }

  private func stopWatchdog() {
    watchdogTimer?.invalidate()
    watchdogTimer = nil
  }

  // MARK: - Retry with backoff

  private func scheduleRetry() {
    retryWorkItem?.cancel()
    isRetrying = true
    let delay = retryDelay
    retryDelay = min(retryDelay * 2, 10)
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.reconnectTask()
    }
    retryWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
  }

  // MARK: - Frame extraction (runs on delegateQueue)

  private func extractFrames() {
    while true {
      guard let soiRange = buffer.range(of: Self.jpegSOI) else { break }
      let searchStart = soiRange.upperBound
      guard searchStart < buffer.endIndex,
            let eoiRange = buffer[searchStart...].range(of: Self.jpegEOI)
      else { break }

      let frameEnd = eoiRange.upperBound
      let jpegData = buffer[soiRange.lowerBound..<frameEnd]
      buffer.removeSubrange(buffer.startIndex..<frameEnd)

      let data = Data(jpegData)
      decodeQueue.async { [weak self] in
        guard let image = UIImage(data: data) else { return }
        DispatchQueue.main.async {
          self?.latestFrame = image
          self?.lastFrameAt = Date()
          self?.retryDelay = 1.0
        }
      }
    }

    let maxBuf = 2 * 1024 * 1024
    if buffer.count > maxBuf {
      buffer.removeAll()
    }
  }
}

// MARK: - URLSessionDataDelegate

extension MJPEGSession: URLSessionDataDelegate {
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    buffer.append(data)
    extractFrames()
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if self.lastFrameAt != nil {
        self.lastFrameAt = nil
        self.reconnectTask()
      } else {
        self.scheduleRetry()
      }
    }
  }
}

// MARK: - FrameSubscriber

/// Bridges an MJPEGSession to a SwiftUI view via Combine.
final class FrameSubscriber: ObservableObject {
  @Published var frame: UIImage?

  private var cancellable: AnyCancellable?
  private var boundURL: URL?

  func bind(hub: MJPEGStreamHub, url: URL?) {
    guard let url else { return }
    if url == boundURL { return }
    boundURL = url
    let session = hub.acquire(url)
    frame = session.latestFrame
    cancellable = session.$latestFrame
      .receive(on: DispatchQueue.main)
      .sink { [weak self] image in
        self?.frame = image
      }
  }

  func unbind(hub: MJPEGStreamHub) {
    cancellable?.cancel()
    cancellable = nil
    if let url = boundURL {
      hub.release(url)
      boundURL = nil
    }
    frame = nil
  }

  func rebind(hub: MJPEGStreamHub, oldURL: URL?, newURL: URL?) {
    if oldURL == newURL { return }
    unbind(hub: hub)
    bind(hub: hub, url: newURL)
  }

  /// Re-subscribe when the target URL changes (e.g. SwiftUI `.task(id:)`).
  func syncURL(hub: MJPEGStreamHub, url: URL?) {
    guard let url else {
      unbind(hub: hub)
      return
    }
    if url == boundURL { return }
    frame = nil
    unbind(hub: hub)
    bind(hub: hub, url: url)
  }
}

// MARK: - SharedMJPEGView

/// Drop-in replacement for the old WKWebView-based MJPEGStreamView.
/// Subscribes to MJPEGStreamHub so identical URLs share a single connection.
struct SharedMJPEGView: View {
  let url: URL?
  let cornerRadius: CGFloat
  @EnvironmentObject private var hub: MJPEGStreamHub
  @StateObject private var subscriber = FrameSubscriber()

  var body: some View {
    ZStack {
      Color.black
      if let frame = subscriber.frame {
        Image(uiImage: frame)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .clipped()
      } else if url == nil {
        Text("No Stream")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(Color(white: 0.33))
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .id(url?.absoluteString ?? "no-stream")
    .onAppear { subscriber.syncURL(hub: hub, url: url) }
    .onChange(of: url?.absoluteString) { _, _ in subscriber.syncURL(hub: hub, url: url) }
    .onDisappear { subscriber.unbind(hub: hub) }
  }
}
