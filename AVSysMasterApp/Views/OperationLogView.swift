import SwiftUI

struct OperationLogView: View {
  @ObservedObject private var logStore = OperationLogStore.shared

  private let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
  }()

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider()
      if logStore.entries.isEmpty {
        emptyState
      } else {
        logList
      }
    }
  }

  private var toolbar: some View {
    HStack {
      Text("Operation Log")
        .font(.headline)
      Spacer()
      Text("\(logStore.entries.count) entries")
        .font(.caption)
        .foregroundStyle(.secondary)
      Button(role: .destructive) {
        logStore.clear()
      } label: {
        Label("Clear", systemImage: "trash")
          .font(.caption)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(logStore.entries.isEmpty)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private var emptyState: some View {
    VStack(spacing: 14) {
      Image(systemName: "text.page.badge.magnifyingglass")
        .font(.system(size: 48))
        .foregroundStyle(.quaternary)
      Text("No Operations Yet")
        .font(.title3.weight(.medium))
        .foregroundStyle(.secondary)
      Text("Tap controls on the main page to see activity here.")
        .font(.subheadline)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  private var logList: some View {
    List {
      ForEach(logStore.entries) { entry in
        LogEntryRow(entry: entry, dateFormatter: dateFormatter)
      }
    }
    .listStyle(.plain)
  }
}

private struct LogEntryRow: View {
  let entry: LogEntry
  let dateFormatter: DateFormatter

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(dateFormatter.string(from: entry.timestamp))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer()
        resultBadge
      }

      HStack(spacing: 6) {
        Text(entry.controlTitle)
          .font(.subheadline.weight(.semibold))
        Image(systemName: "arrow.right")
          .font(.caption2)
          .foregroundStyle(.tertiary)
        Text(entry.commandName)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 8) {
        Label(entry.deviceName, systemImage: "cpu")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(entry.deviceHost)
          .font(.caption.monospaced())
          .foregroundStyle(.tertiary)
      }

      if !entry.payload.isEmpty {
        Text(entry.payload.prefix(80) + (entry.payload.count > 80 ? "..." : ""))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
      }

      if case .failure(let msg) = entry.result {
        Text(msg)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .padding(.vertical, 4)
  }

  private var resultBadge: some View {
    Group {
      switch entry.result {
      case .pending:
        HStack(spacing: 4) {
          ProgressView().scaleEffect(0.6)
          Text("Sending")
            .font(.caption2.weight(.medium))
        }
        .foregroundStyle(.orange)
      case .success:
        Label("OK", systemImage: "checkmark.circle.fill")
          .font(.caption2.weight(.medium))
          .foregroundStyle(.green)
      case .failure:
        Label("Error", systemImage: "xmark.circle.fill")
          .font(.caption2.weight(.medium))
          .foregroundStyle(.red)
      }
    }
  }
}
