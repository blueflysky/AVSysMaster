import SwiftUI

struct ControlPageView: View {
  @Binding var showSettings: Bool
  @EnvironmentObject private var modelStore: UnifiedModelStore
  @EnvironmentObject private var runtimeStore: RuntimeControlStore
  @EnvironmentObject private var transport: TcpTransport

  @AppStorage("control.isEditMode") private var isEditMode = false
  @State private var alertMessage: AlertMessage?
  @State private var toastMessage: String?
  @State private var toastWorkItem: DispatchWorkItem?
  @State private var offlineLabels: [String: String] = [:]
  @State private var retryTasks: [String: Task<Void, Never>] = [:]
  @State private var selectedMatrixInput: SelectedMatrixInput? = nil

  @StateObject private var triggerEngine = CommandTriggerEngine()

  /// Drag state for routing exploded matrixInput → matrixOutput tiles on the canvas.
  @State private var explodedChipDrag: ExplodedChipDrag? = nil

  var body: some View {
    GeometryReader { geo in
      ZStack {
        background
        overlayLayer
        controlsGrid(size: geo.size)
      }
      .overlay(alignment: .topLeading) {
        topBar
      }
      .overlay(alignment: .bottomLeading) {
        toastOverlay
      }
      .contentShape(Rectangle())
      .overlay {
        FourFingerLongPressCaptureView(minimumDuration: 1.0) {
          showSettings = true
        }
      }
#if DEBUG
      .onTapGesture(count: 3) {
#if targetEnvironment(simulator)
        showSettings = true
#endif
      }
#endif
      .onAppear {
        modelStore.runtimeCanvasSize = geo.size
        triggerEngine.start(transport: transport, model: modelStore.runtime)
      }
      .onChange(of: modelStore.runtime.triggerRules) {
        triggerEngine.start(transport: transport, model: modelStore.runtime)
      }
    }
#if targetEnvironment(simulator)
    .background {
      Button("") { showSettings = true }
        .keyboardShortcut(",", modifiers: .command)
        .hidden()
    }
#endif
    .alert(item: $alertMessage) { item in
      Alert(title: Text(item.message))
    }
  }

  // MARK: - Toast & Offline Indicator

  @ViewBuilder
  private var toastOverlay: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(offlineLabels.values.sorted()), id: \.self) { label in
        toastChip("Offline · \(label) · retrying…", persistent: true)
      }
      if let msg = toastMessage {
        toastChip(msg, persistent: false)
      }
    }
    .padding(.leading, 14)
    .padding(.bottom, 14)
    .allowsHitTesting(false)
    .animation(.easeOut(duration: 0.25), value: offlineLabels.count)
  }

  private func toastChip(_ text: String, persistent: Bool) -> some View {
    Text(text)
      .font(.system(size: 11, weight: .medium))
      .foregroundStyle(.white.opacity(persistent ? 0.75 : 0.85))
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        .black.opacity(0.55),
        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
      )
      .transition(.opacity.combined(with: .move(edge: .bottom)))
  }

  private func showToast(_ message: String, duration: TimeInterval = 5) {
    toastWorkItem?.cancel()
    withAnimation(.easeOut(duration: 0.25)) { toastMessage = message }
    let work = DispatchWorkItem { [self] in
      withAnimation(.easeIn(duration: 0.4)) { toastMessage = nil }
    }
    toastWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
  }

  // MARK: - Background Retry

  private func deviceKey(_ device: DeviceItem) -> String { "\(device.host):\(device.port)" }

  private func startBackgroundRetry(
    device: DeviceItem, command: CommandItem, controlTitle: String
  ) {
    let key = deviceKey(device)
    let label = "\(device.host) \(device.name)"

    retryTasks[key]?.cancel()
    withAnimation { offlineLabels[key] = label }

    let task = Task {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        guard !Task.isCancelled else { break }
        do {
          try await transport.send(device: device, command: command)
          await MainActor.run {
            _ = withAnimation { offlineLabels.removeValue(forKey: key) }
            retryTasks.removeValue(forKey: key)
            OperationLogStore.shared.append(
              controlTitle: controlTitle, commandName: "Background retry OK",
              payload: command.payload, deviceName: device.name, deviceHost: device.host
            )
            OperationLogStore.shared.markLastResult(.success)
            runtimeStore.triggerHaptic(.rigid)
            showToast("Reconnected · \(label)")
          }
          break
        } catch {
          print("[TCP] Background retry failed for \(key): \(error.localizedDescription)")
        }
      }
    }
    retryTasks[key] = task
  }

  private func cancelBackgroundRetry(for device: DeviceItem) {
    let key = deviceKey(device)
    retryTasks[key]?.cancel()
    retryTasks.removeValue(forKey: key)
    _ = withAnimation { offlineLabels.removeValue(forKey: key) }
  }

  private var topBar: some View {
    let s = modelStore.runtime.styles
    return ZStack(alignment: .topLeading) {
      Color.clear
      if let logo = VisualTheme.logoImage(path: s.logoPath) {
        logo
          .resizable()
          .scaledToFit()
          .frame(width: s.logoWidth, height: s.logoHeight)
          .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
          .offset(x: s.logoX, y: s.logoY)
      }
    }
    .allowsHitTesting(false)
  }

  private var currentTheme: ThemeColors {
    ThemeColors.forTheme(modelStore.runtime.styles.uiTheme)
  }

  private var background: some View {
    Group {
      if let bg = VisualTheme.backgroundImage(path: modelStore.runtime.styles.backgroundPath) {
        bg.resizable().scaledToFill().ignoresSafeArea()
      } else {
        ZStack {
          currentTheme.background.ignoresSafeArea()
          if currentTheme.hasGradient {
            currentTheme.gradient.ignoresSafeArea()
          }
        }
      }
    }
  }

  private var overlayLayer: some View {
    Group {
      if modelStore.runtime.styles.backgroundPath != nil {
        Color.black.opacity(0.2).ignoresSafeArea()
      } else if currentTheme.hasOverlay {
        currentTheme.overlay.ignoresSafeArea()
      }
    }
  }

  // MARK: - Grid-Positioned Controls

  @ViewBuilder
  private func controlsGrid(size: CGSize) -> some View {
    let layout = activeLayout(for: Int(size.width))
    let columns = max(1, layout.columns)
    let cellW = size.width / CGFloat(columns)
    let cellH = cellW

    ZStack(alignment: .topLeading) {
      ForEach(modelStore.runtime.controls.filter { !$0.isExplodedMatrixParentHiddenFromCanvas }) { control in
        let tileW = CGFloat(control.placement.w) * cellW
        let tileH = CGFloat(control.placement.h) * cellH
        let centerX = CGFloat(control.placement.x) * cellW + tileW / 2
        let centerY = CGFloat(control.placement.y) * cellH + tileH / 2

        if control.type == .matrix {
          MatrixTileView(
            control: control,
            device: modelStore.runtime.devices.first(where: { $0.id == control.binding?.deviceID }),
            transport: transport,
            runtimeStore: runtimeStore,
            styles: modelStore.runtime.styles,
            theme: currentTheme,
            selectedInput: $selectedMatrixInput
          )
          .frame(width: max(tileW - 6, 24), height: max(tileH - 6, 24))
          .position(x: centerX, y: centerY)
        } else if control.type == .liveMatrix {
          LiveMatrixTileView(
            control: control,
            device: modelStore.runtime.devices.first(where: { $0.id == control.binding?.deviceID }),
            transport: transport,
            runtimeStore: runtimeStore,
            styles: modelStore.runtime.styles,
            theme: currentTheme,
            tileSize: CGSize(width: max(tileW - 6, 24), height: max(tileH - 6, 24))
          )
          .frame(width: max(tileW - 6, 24), height: max(tileH - 6, 24))
          .position(x: centerX, y: centerY)
        } else if control.type == .volumeLevel {
          VolumeLevelTileView(
            control: control,
            device: modelStore.runtime.devices.first(where: { $0.id == control.binding?.deviceID }),
            commands: modelStore.runtime.commands,
            transport: transport,
            runtimeStore: runtimeStore,
            styles: modelStore.runtime.styles,
            theme: currentTheme,
            isEditMode: isEditMode
          )
          .frame(width: max(tileW - 6, 24), height: max(tileH - 6, 24))
          .position(x: centerX, y: centerY)
        } else if control.type == .matrixInput || control.type == .matrixOutput
                    || control.type == .liveMatrixInput || control.type == .liveMatrixOutput {
          let parentDevice: DeviceItem? = {
            if let dev = modelStore.runtime.devices.first(where: { $0.id == control.binding?.deviceID }) {
              return dev
            }
            guard let pid = UUID(uuidString: control.customFields["parentControlID"] ?? ""),
                  let parent = modelStore.runtime.controls.first(where: { $0.id == pid }),
                  let bid = parent.binding?.deviceID else { return nil }
            return modelStore.runtime.devices.first(where: { $0.id == bid })
          }()
          MatrixChipTileView(
            control: control,
            allControls: modelStore.runtime.controls,
            device: parentDevice,
            transport: transport,
            runtimeStore: runtimeStore,
            styles: modelStore.runtime.styles,
            theme: currentTheme,
            canvasCellW: cellW,
            selectedInput: $selectedMatrixInput,
            explodedDrag: $explodedChipDrag
          )
          .frame(width: max(tileW - 6, 24), height: max(tileH - 6, 24))
          .position(x: centerX, y: centerY)
        } else {
          ControlTileView(
            control: control,
            state: runtimeStore.state(for: control.id),
            styles: modelStore.runtime.styles,
            theme: currentTheme,
            onTap: { performControl(control) }
          )
          .frame(width: max(tileW - 6, 24), height: max(tileH - 6, 24))
          .position(x: centerX, y: centerY)
        }
      }
      // Ghost chip: follows the finger during exploded-chip drag routing.
      if let drag = explodedChipDrag {
        let gw = max(cellW * 2, 64)
        let gh = max(cellW * 1.4, 44)
        let parentFields = modelStore.runtime.controls
          .first { $0.id.uuidString == drag.parentID }?.customFields ?? [:]
        let staticInputAccent = MatrixNamesHelper.parseColor(parentFields["matrixInputColor"] ?? "blue")
        let staticDragColor = MatrixNamesHelper.matrixDragColor(
          in: parentFields, fallback: staticInputAccent)
        let ghostFill = drag.isLive
          ? currentTheme.activeButtonBg.opacity(0.92)
          : staticDragColor.opacity(0.75)
        let ghostStroke = drag.isLive ? currentTheme.activeBorder : staticDragColor
        ZStack {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(ghostFill)
          Text(drag.chipName)
            .font(.system(size: max(min(14, gw * 0.14), 8), weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, 8)
        }
        .overlay {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(ghostStroke, lineWidth: 2.5)
        }
        .frame(width: gw, height: gh)
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        .scaleEffect(1.06)
        .opacity(0.9)
        .position(x: drag.position.x, y: drag.position.y - gh * 0.7)
        .allowsHitTesting(false)
        .zIndex(200)
      }
    }
    .coordinateSpace(name: "controlsGrid")
    .frame(width: size.width, height: size.height)
  }

  private func activeLayout(for width: Int) -> LayoutItem {
    modelStore.runtime.layouts
      .sorted(by: { $0.breakpoint < $1.breakpoint })
      .last(where: { width >= $0.breakpoint }) ?? .defaultLayout
  }

  private func performControl(_ control: ControlItem) {
    guard !isEditMode else { return }
    if control.type == .label || control.type == .border
        || control.type == .matrix || control.type == .liveMatrix || control.type == .volumeLevel
        || control.type == .matrixInput || control.type == .matrixOutput
        || control.type == .liveMatrixInput || control.type == .liveMatrixOutput { return }
    guard let binding = control.binding,
      let device = modelStore.runtime.devices.first(where: { $0.id == binding.deviceID })
    else {
      alertMessage = AlertMessage(message: L10n.validationFailed)
      return
    }

    if control.type == .icon {
      performIconToggle(control: control, device: device, binding: binding)
      return
    }

    if control.type == .toggle {
      performToggleControl(control: control, device: device, binding: binding)
      return
    }

    guard let command = modelStore.runtime.commands.first(where: { $0.id == binding.commandID })
    else {
      alertMessage = AlertMessage(message: L10n.validationFailed)
      return
    }

    // Resolve extra commands and interval
    let extraCommands: [CommandItem] = (control.customFields["extraCommandIDs"] ?? "")
      .split(separator: ",")
      .compactMap { UUID(uuidString: String($0).trimmingCharacters(in: .whitespaces)) }
      .compactMap { id in modelStore.runtime.commands.first(where: { $0.id == id }) }
    let intervalNs = UInt64(max(0, Int(control.customFields["multiCmdIntervalMs"] ?? "") ?? 0)) * 1_000_000

    runtimeStore.triggerHaptic(.light)
    runtimeStore.markBusy(control.id)

    Task {
      do {
        OperationLogStore.shared.append(
          controlTitle: control.title, commandName: command.name, payload: command.payload,
          deviceName: device.name, deviceHost: device.host
        )
        let retries = try await transport.sendWithRetry(device: device, command: command)
        await MainActor.run {
          OperationLogStore.shared.markLastResult(.success)
          cancelBackgroundRetry(for: device)
        }
        if retries > 0 { await MainActor.run { showToast("Reconnected · \(device.host) \(device.name)") } }

        for extraCmd in extraCommands {
          if intervalNs > 0 {
            try await Task.sleep(nanoseconds: intervalNs)
          }
          OperationLogStore.shared.append(
            controlTitle: control.title, commandName: extraCmd.name, payload: extraCmd.payload,
            deviceName: device.name, deviceHost: device.host
          )
          try await transport.sendWithRetry(device: device, command: extraCmd)
          await MainActor.run { OperationLogStore.shared.markLastResult(.success) }
        }

        await MainActor.run {
          runtimeStore.applyBehavior(control: control, allControls: modelStore.runtime.controls)
        }
      } catch {
        await MainActor.run {
          runtimeStore.markError(control.id)
          runtimeStore.triggerErrorHaptic()
          OperationLogStore.shared.markLastResult(.failure(error.localizedDescription))
          startBackgroundRetry(device: device, command: command, controlTitle: control.title)
        }
      }
    }
  }

  private func performIconToggle(
    control: ControlItem, device: DeviceItem, binding: ControlBinding
  ) {
    let isCurrentlyActive = runtimeStore.state(for: control.id) == .active
    let commandID: UUID = {
      if isCurrentlyActive,
        let offID = UUID(uuidString: control.customFields["commandID_off"] ?? "")
      {
        return offID
      }
      return binding.commandID
    }()

    guard let command = modelStore.runtime.commands.first(where: { $0.id == commandID }) else {
      alertMessage = AlertMessage(message: L10n.validationFailed)
      return
    }

    let extraPairs = resolveExtraCommandDevicePairs(
      control: control, isOff: isCurrentlyActive, fallbackDevice: device
    )
    let intervalNs = UInt64(max(0, Int(control.customFields["multiCmdIntervalMs"] ?? "") ?? 0)) * 1_000_000

    runtimeStore.triggerHaptic(.medium)
    let newActive = !isCurrentlyActive
    if newActive {
      runtimeStore.markActive(control.id)
    } else {
      runtimeStore.markIdle(control.id)
    }

    let tag = isCurrentlyActive ? " [OFF]" : " [ON]"
    OperationLogStore.shared.append(
      controlTitle: control.title,
      commandName: command.name + tag,
      payload: command.payload, deviceName: device.name, deviceHost: device.host
    )

    Task {
      do {
        let retries = try await transport.sendWithRetry(device: device, command: command)
        await MainActor.run {
          OperationLogStore.shared.markLastResult(.success)
          cancelBackgroundRetry(for: device)
        }
        if retries > 0 { await MainActor.run { showToast("Reconnected · \(device.host) \(device.name)") } }

        for (extraCmd, extraDev) in extraPairs {
          if intervalNs > 0 { try await Task.sleep(nanoseconds: intervalNs) }
          OperationLogStore.shared.append(
            controlTitle: control.title, commandName: extraCmd.name + tag,
            payload: extraCmd.payload, deviceName: extraDev.name, deviceHost: extraDev.host
          )
          try await transport.sendWithRetry(device: extraDev, command: extraCmd)
          await MainActor.run { OperationLogStore.shared.markLastResult(.success) }
        }

        await MainActor.run { runtimeStore.triggerHaptic(.rigid) }
      } catch {
        await MainActor.run {
          runtimeStore.triggerErrorHaptic()
          OperationLogStore.shared.markLastResult(.failure(error.localizedDescription))
          startBackgroundRetry(device: device, command: command, controlTitle: control.title)
        }
      }
    }
  }

  private func performToggleControl(
    control: ControlItem, device: DeviceItem, binding: ControlBinding
  ) {
    let isCurrentlyActive = runtimeStore.state(for: control.id) == .active

    let offCommandID = UUID(uuidString: control.customFields["commandID_off"] ?? "")
    let commandID = (isCurrentlyActive && offCommandID != nil) ? offCommandID! : binding.commandID

    guard let command = modelStore.runtime.commands.first(where: { $0.id == commandID }) else {
      alertMessage = AlertMessage(message: L10n.validationFailed)
      return
    }

    let extraPairs = resolveExtraCommandDevicePairs(
      control: control, isOff: isCurrentlyActive, fallbackDevice: device
    )
    let intervalNs = UInt64(max(0, Int(control.customFields["multiCmdIntervalMs"] ?? "") ?? 0)) * 1_000_000

    runtimeStore.triggerHaptic(.medium)
    let newActive = !isCurrentlyActive
    if newActive {
      runtimeStore.markActive(control.id)
    } else {
      runtimeStore.markIdle(control.id)
    }

    let tag = isCurrentlyActive ? " [OFF]" : " [ON]"
    OperationLogStore.shared.append(
      controlTitle: control.title,
      commandName: command.name + tag,
      payload: command.payload, deviceName: device.name, deviceHost: device.host
    )

    Task {
      do {
        let retries = try await transport.sendWithRetry(device: device, command: command)
        await MainActor.run {
          OperationLogStore.shared.markLastResult(.success)
          cancelBackgroundRetry(for: device)
        }
        if retries > 0 { await MainActor.run { showToast("Reconnected · \(device.host) \(device.name)") } }

        for (extraCmd, extraDev) in extraPairs {
          if intervalNs > 0 { try await Task.sleep(nanoseconds: intervalNs) }
          OperationLogStore.shared.append(
            controlTitle: control.title, commandName: extraCmd.name + tag,
            payload: extraCmd.payload, deviceName: extraDev.name, deviceHost: extraDev.host
          )
          try await transport.sendWithRetry(device: extraDev, command: extraCmd)
          await MainActor.run { OperationLogStore.shared.markLastResult(.success) }
        }

        await MainActor.run { runtimeStore.triggerHaptic(.rigid) }
      } catch {
        await MainActor.run {
          runtimeStore.triggerErrorHaptic()
          OperationLogStore.shared.markLastResult(.failure(error.localizedDescription))
          startBackgroundRetry(device: device, command: command, controlTitle: control.title)
        }
      }
    }
  }

  // MARK: - Multi-Command Multi-Device Helper

  /// Resolves extra command-device pairs from customFields.
  /// Keys: `extraCommandIDs_on` / `extraCommandIDs_off` (comma-separated command UUIDs)
  ///        `extraDeviceIDs_on` / `extraDeviceIDs_off` (comma-separated device UUIDs, parallel to commands)
  /// If a device slot is missing or invalid, falls back to the bound device.
  private func resolveExtraCommandDevicePairs(
    control: ControlItem, isOff: Bool, fallbackDevice: DeviceItem
  ) -> [(CommandItem, DeviceItem)] {
    let suffix = isOff ? "_off" : "_on"
    let cmdIDs = (control.customFields["extraCommandIDs\(suffix)"] ?? "")
      .split(separator: ",")
      .map { UUID(uuidString: String($0).trimmingCharacters(in: .whitespaces)) }
    let devIDs = (control.customFields["extraDeviceIDs\(suffix)"] ?? "")
      .split(separator: ",")
      .map { UUID(uuidString: String($0).trimmingCharacters(in: .whitespaces)) }

    return cmdIDs.enumerated().compactMap { idx, cmdID in
      guard let cmdID, let cmd = modelStore.runtime.commands.first(where: { $0.id == cmdID })
      else { return nil }
      let dev: DeviceItem = {
        if idx < devIDs.count,
          let devID = devIDs[idx],
          let d = modelStore.runtime.devices.first(where: { $0.id == devID })
        { return d }
        return fallbackDevice
      }()
      return (cmd, dev)
    }
  }
}

// MARK: - Control Tile View

private struct ControlTileView: View {
  let control: ControlItem
  let state: VisualState
  let styles: StyleItem
  let theme: ThemeColors
  let onTap: () -> Void

  @State private var pressing = false
  @State private var holdProgress: CGFloat = 0
  @State private var holdTimer: Timer? = nil
  /// Start time for the current hold gesture (icon / toggle long-press).
  @State private var holdStartTime: Date?
  /// Prevents repeat firing while finger remains down after a successful hold.
  @State private var holdTriggeredInCurrentPress = false

  /// Long-press duration before toggle fires. Icon controls read `iconHoldDurationSec` (0.1s steps, default 3s).
  private var holdDurationSeconds: TimeInterval {
    switch control.type {
    case .icon:
      let raw = Double(control.customFields["iconHoldDurationSec"] ?? "") ?? 3.0
      let stepped = (raw * 10).rounded() / 10
      return min(max(stepped, 0.1), 60.0)
    case .toggle:
      return 3.0
    default:
      return 3.0
    }
  }

  private var holdCountdown: Int {
    let d = holdDurationSeconds
    return max(1, Int(ceil(d * (1.0 - Double(holdProgress)))))
  }

  private func startHold(isBusy: Bool) {
    guard !isBusy, holdTimer == nil, !holdTriggeredInCurrentPress else { return }
    pressing = true
    holdProgress = 0
    holdStartTime = Date()
    let targetDuration = holdDurationSeconds
    let tick: TimeInterval = 0.04
    let t = Timer(timeInterval: tick, repeats: true) { _ in
      DispatchQueue.main.async {
        guard let start = holdStartTime else { return }
        let elapsed = Date().timeIntervalSince(start)
        holdProgress = CGFloat(min(1.0, elapsed / targetDuration))
        if elapsed >= targetDuration {
          holdProgress = 1.0
          holdTriggeredInCurrentPress = true
          cancelHold()
          onTap()
        }
      }
    }
    RunLoop.main.add(t, forMode: .common)
    holdTimer = t
  }

  private func cancelHold() {
    holdTimer?.invalidate()
    holdTimer = nil
    holdStartTime = nil
    pressing = false
    withAnimation(.easeOut(duration: 0.25)) { holdProgress = 0 }
  }

  var body: some View {
    switch control.type {
    case .label:
      labelTile
    case .icon:
      iconTile
    case .toggle:
      toggleTile
    case .button, .slider:
      buttonTile
    case .border:
      borderTile
    case .matrix, .liveMatrix, .volumeLevel,
         .matrixInput, .matrixOutput, .liveMatrixInput, .liveMatrixOutput:
      EmptyView()
    }
  }

  // MARK: - Border

  @ViewBuilder
  private var borderTile: some View {
    let thickness = CGFloat(Double(control.customFields["borderThickness"] ?? "") ?? 2)
    let radius = CGFloat(Double(control.customFields["borderCornerRadius"] ?? "") ?? 12)
    let mode = control.customFields["borderColorMode"] ?? "solid"
    let solidColor = Color(hexString: control.customFields["borderColor"] ?? "#FFFFFF")
    let fromColor = Color(hexString: control.customFields["borderGradientFrom"] ?? "#FFFFFF")
    let toColor = Color(hexString: control.customFields["borderGradientTo"] ?? "#0080FF")
    let angle = Double(control.customFields["borderGradientAngle"] ?? "") ?? 0
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    if mode == "gradient" {
      let pts = borderGradientPoints(angle)
      shape.strokeBorder(
        LinearGradient(colors: [fromColor, toColor], startPoint: pts.0, endPoint: pts.1),
        lineWidth: thickness
      )
    } else {
      shape.strokeBorder(solidColor, lineWidth: thickness)
    }
  }

  // MARK: - Label

  private var labelTile: some View {
    let fontSize = Double(control.customFields["fontSize"] ?? "") ?? 18
    let weight = parseFontWeight(control.customFields["fontWeight"] ?? "semibold")
    let align = parseAlignment(control.customFields["textAlign"] ?? "left")
    let color = parseColor(control.customFields["textColor"] ?? "white")
    let iconName = control.customFields["labelIconName"] ?? ""
    let iconSize = CGFloat(Double(control.customFields["labelIconSize"] ?? "") ?? 24)
    let iconPos = control.customFields["labelIconPosition"] ?? "leading"
    let iconColor = parseColor(
      control.customFields["labelIconColor"] ?? (control.customFields["textColor"] ?? "white"))

    let hideText = control.customFields["labelHideText"] == "1"
    let textView = AnyView(Text(control.title)
      .font(.system(size: fontSize, weight: weight))
      .foregroundStyle(color)
      .multilineTextAlignment(align.text)
      .lineLimit(6)
      .minimumScaleFactor(0.4))
    let iconView = iconName.isEmpty ? AnyView(EmptyView()) : AnyView(
      Image(systemName: iconName)
        .font(.system(size: iconSize))
        .foregroundStyle(iconColor)
    )
    let content: AnyView
    if iconName.isEmpty || !hideText {
      switch iconPos {
      case "trailing":
        content = AnyView(HStack(spacing: 6) { textView; iconView })
      case "top":
        content = AnyView(VStack(spacing: 4) { iconView; textView })
      case "bottom":
        content = AnyView(VStack(spacing: 4) { textView; iconView })
      default:
        content = AnyView(HStack(spacing: 6) { iconView; textView })
      }
    } else {
      content = iconView
    }

    return content
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: align.frame)
      .padding(12)
  }

  // MARK: - Icon Toggle

  @State private var busyRotation: Double = 0

  private var iconTile: some View {
    let isOn = state == .active
    let isBusy = state == .busy
    let isError = state == .error
    let iconName: String = {
      if isBusy { return "arrow.triangle.2.circlepath" }
      if isError { return "exclamationmark.triangle.fill" }
      return isOn
        ? (control.customFields["iconOn"] ?? "power.circle.fill")
        : (control.customFields["iconOff"] ?? "power.circle")
    }()
    let iconSize = Double(control.customFields["iconSize"] ?? "") ?? 44
    let color: Color = {
      if isError { return .red }
      if isBusy { return .orange }
      return isOn
        ? parseColor(control.customFields["iconColorOn"] ?? "green")
        : parseColor(control.customFields["iconColorOff"] ?? "gray")
    }()

    return ZStack {
      Image(systemName: iconName)
        .font(.system(size: iconSize))
        .foregroundStyle(color)
        .rotationEffect(.degrees(isBusy ? busyRotation : 0))
        .scaleEffect(pressing ? 0.85 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: pressing)
        .animation(.easeInOut(duration: 0.3), value: isOn)
        .animation(.easeInOut(duration: 0.2), value: isError)

      // Countdown ring + number
      if holdProgress > 0 {
        let ringSize = min(iconSize + 28, 88)
        ZStack {
          Circle()
            .stroke(.white.opacity(0.15), lineWidth: 4)
            .frame(width: ringSize, height: ringSize)
          Circle()
            .trim(from: 0, to: holdProgress)
            .stroke(
              isOn ? Color.red : Color.green,
              style: StrokeStyle(lineWidth: 4, lineCap: .round)
            )
            .frame(width: ringSize, height: ringSize)
            .rotationEffect(.degrees(-90))
            .animation(.linear(duration: 0.04), value: holdProgress)
          Text("\(holdCountdown)")
            .font(.system(size: max(iconSize * 0.35, 12), weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .offset(y: ringSize * 0.42)
        }
        .transition(.scale(scale: 0.6).combined(with: .opacity))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
    .onChange(of: isBusy) { _, busy in
      if busy {
        withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
          busyRotation = 360
        }
      } else {
        busyRotation = 0
      }
    }
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in startHold(isBusy: isBusy) }
        .onEnded { _ in
          if holdProgress < 1.0 { cancelHold() }
          holdTriggeredInCurrentPress = false
        }
    )
  }

  // MARK: - Toggle Switch

  private var toggleTile: some View {
    let isOn = state == .active
    let isBusy = state == .busy
    let isError = state == .error
    let fontSize = Double(control.customFields["fontSize"] ?? "") ?? 15
    let weight = parseFontWeight(control.customFields["fontWeight"] ?? "semibold")
    let textColor = parseColor(control.customFields["textColor"] ?? "white")
    let accentColor: Color = isError ? .red : (isOn ? theme.toggleBg : .gray.opacity(0.5))

    return HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(control.title)
          .font(.system(size: fontSize, weight: weight))
          .foregroundStyle(textColor)
          .lineLimit(2)
          .minimumScaleFactor(0.5)
        if holdProgress > 0 {
          Text(isOn ? L10n.holdToTurnOff(holdCountdown) : L10n.holdToTurnOn(holdCountdown))
            .font(.system(size: max(fontSize * 0.72, 9), weight: .medium))
            .foregroundStyle(isOn ? Color.red.opacity(0.9) : Color.green.opacity(0.9))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .animation(.easeOut(duration: 0.15), value: holdProgress > 0)

      Spacer()

      // Countdown ring wrapping the switch capsule
      ZStack {
        // Track ring
        if holdProgress > 0 {
          Circle()
            .stroke(.white.opacity(0.15), lineWidth: 3)
            .frame(width: 44, height: 44)
          Circle()
            .trim(from: 0, to: holdProgress)
            .stroke(
              isOn ? Color.red : Color.green,
              style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
            .frame(width: 44, height: 44)
            .rotationEffect(.degrees(-90))
            .animation(.linear(duration: 0.04), value: holdProgress)
        }

        // Switch capsule
        ZStack {
          Capsule()
            .fill(accentColor)
            .frame(width: 50, height: 28)
          if isBusy {
            ProgressView()
              .scaleEffect(0.7)
              .tint(.white)
          } else {
            Circle()
              .fill(.white)
              .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
              .frame(width: 24, height: 24)
              .offset(x: isOn ? 11 : -11)
              .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isOn)
          }
        }
      }
      .frame(width: 50, height: 44)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(theme.idleButtonBg)
    )
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .shadow(color: .black.opacity(0.3), radius: styles.shadowBlur, x: 0, y: styles.shadowY)
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(isOn ? theme.activeBorder : theme.idleBorder, lineWidth: 1.5)
    }
    .scaleEffect(pressing ? 0.97 : 1.0)
    .animation(.easeOut(duration: 0.16), value: pressing)
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in startHold(isBusy: isBusy) }
        .onEnded { _ in
          if holdProgress < 1.0 { cancelHold() }
          holdTriggeredInCurrentPress = false
        }
    )
  }

  // MARK: - Button / Slider

  private var buttonTile: some View {
    let isBusy = state == .busy
    let fontSize = Double(control.customFields["fontSize"] ?? "") ?? 17
    let weight = parseFontWeight(control.customFields["fontWeight"] ?? "semibold")
    let align = parseAlignment(control.customFields["textAlign"] ?? "center")
    let color = parseColor(control.customFields["textColor"] ?? "white")

    let extraCount: Int = (control.customFields["extraCommandIDs"] ?? "")
      .split(separator: ",").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count

    return Button(action: { if !isBusy { onTap() } }) {
      ZStack(alignment: .topTrailing) {
        Text(control.title)
          .font(.system(size: fontSize, weight: weight))
          .foregroundStyle(isBusy ? color.opacity(0.5) : color)
          .multilineTextAlignment(align.text)
          .lineLimit(3)
          .minimumScaleFactor(0.5)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: align.frame)
          .padding(12)

        if isBusy {
          ProgressView()
            .scaleEffect(0.8)
            .tint(.white)
        }

        // Multi-command badge
        if extraCount > 0 && !isBusy {
          Text("×\(extraCount + 1)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(5)
        }
      }
      .background(tileColor)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .shadow(color: .black.opacity(0.35), radius: styles.shadowBlur, x: 0, y: styles.shadowY)
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(tileBorderColor, lineWidth: tileBorderWidth)
          .shadow(
            color: state == .active ? theme.activeBorder.opacity(styles.glowOpacity) : .clear,
            radius: 8
          )
      }
      .scaleEffect(pressing ? 0.95 : 1.0)
      .animation(.spring(response: 0.25, dampingFraction: 0.65), value: pressing)
      .animation(.easeInOut(duration: 0.25), value: state)
    }
    .buttonStyle(.plain)
    .disabled(isBusy)
    .simultaneousGesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in if !isBusy { pressing = true } }
        .onEnded { _ in pressing = false }
    )
  }

  // MARK: - Helpers

  private var tileColor: Color {
    switch state {
    case .idle: return theme.idleButtonBg
    case .busy: return theme.idleButtonBg.opacity(0.8)
    case .active: return theme.activeButtonBg
    case .error: return .red.opacity(0.62)
    }
  }

  private var tileBorderColor: Color {
    switch state {
    case .idle: return theme.idleBorder
    case .busy: return .orange.opacity(0.6)
    case .active: return theme.activeBorder
    case .error: return .red.opacity(0.7)
    }
  }

  private var tileBorderWidth: CGFloat {
    state == .idle ? 1.5 : 2.0
  }

  private func parseFontWeight(_ value: String) -> Font.Weight {
    switch value {
    case "regular": return .regular
    case "medium": return .medium
    case "bold": return .bold
    default: return .semibold
    }
  }

  private func parseAlignment(_ value: String) -> (text: TextAlignment, frame: Alignment) {
    switch value {
    case "center": return (.center, .center)
    case "right": return (.trailing, .trailing)
    default: return (.leading, .leading)
    }
  }

  private func parseColor(_ value: String) -> Color {
    if value.hasPrefix("#") { return Color(hexString: value) }
    switch value {
    case "black": return .black
    case "gray": return .gray
    case "blue": return .blue
    case "green": return .green
    case "orange": return .orange
    case "red": return .red
    case "cyan": return .cyan
    case "yellow": return .yellow
    case "purple": return .purple
    case "pink": return .pink
    case "mint": return .mint
    case "teal": return .teal
    default: return .white
    }
  }
}

// MARK: - Matrix Tile View

private struct MatrixTileView: View {
  let control: ControlItem
  let device: DeviceItem?
  let transport: TcpTransport
  @ObservedObject var runtimeStore: RuntimeControlStore
  let styles: StyleItem
  let theme: ThemeColors
  @Binding var selectedInput: SelectedMatrixInput?

  @State private var dragSourceInput: Int?
  @State private var dragPosition: CGPoint = .zero
  @State private var isDragging = false
  @State private var highlightedOutput: Int?
  @State private var chipFrames: [String: CGRect] = [:]
  @State private var sendingRoute: String?
  @State private var routeGenerations: [Int: UInt64] = [:]
  @State private var routeGenerationCounter: UInt64 = 0
  /// Merge animation state
  @State private var isMerging = false
  @State private var mergeScale: CGFloat = 1.0
  @State private var mergeOpacity: Double = 1.0
  /// Output chip that was just blocked (drives shake animation)
  @State private var blockedOutput: Int? = nil
  @State private var blockedShakeCounter: CGFloat = 0

  private var inputCount: Int { Int(control.customFields["matrixInputCount"] ?? "") ?? 4 }
  private var outputCount: Int { Int(control.customFields["matrixOutputCount"] ?? "") ?? 4 }
  private var template: String { control.customFields["matrixCommandTemplate"] ?? "{output} VS {input}" }
  private var lineEnding: LineEnding { LineEnding(rawValue: control.customFields["matrixLineEnding"] ?? "crlf") ?? .crlf }
  private var timeoutMs: Int { Int(control.customFields["matrixTimeoutMs"] ?? "") ?? 1500 }
  private var chipW: CGFloat { CGFloat(Double(control.customFields["matrixChipWidth"] ?? "") ?? 80) }
  private var chipH: CGFloat { CGFloat(Double(control.customFields["matrixChipHeight"] ?? "") ?? 52) }
  private var chipFontSize: CGFloat { CGFloat(Double(control.customFields["matrixFontSize"] ?? "") ?? 14) }
  private var chipFontWeight: Font.Weight { matrixParseFontWeight(control.customFields["matrixFontWeight"] ?? "semibold") }
  private var titleFontSize: CGFloat { CGFloat(Double(control.customFields["matrixTitleFontSize"] ?? "") ?? 11) }
  private var titleChipSpacing: CGFloat { CGFloat(Double(control.customFields["matrixTitleChipSpacing"] ?? "") ?? 10) }
  private var chipSpacing: CGFloat { CGFloat(Double(control.customFields["matrixChipSpacing"] ?? "") ?? 6) }
  private var sectionSpacing: CGFloat { CGFloat(Double(control.customFields["matrixSectionSpacing"] ?? "") ?? 8) }

  private var inputWidths: [CGFloat] { MatrixNamesHelper.parseSizes(control.customFields["matrixInputWidths"], count: inputCount, fallback: chipW) }
  private var inputHeights: [CGFloat] { MatrixNamesHelper.parseSizes(control.customFields["matrixInputHeights"], count: inputCount, fallback: chipH) }
  private var outputWidths: [CGFloat] { MatrixNamesHelper.parseSizes(control.customFields["matrixOutputWidths"], count: outputCount, fallback: chipW) }
  private var outputHeights: [CGFloat] { MatrixNamesHelper.parseSizes(control.customFields["matrixOutputHeights"], count: outputCount, fallback: chipH) }

  private var inputOffsetX: [CGFloat] { MatrixNamesHelper.parseSizes(control.customFields["matrixInputOffsetX"], count: inputCount, fallback: 0) }
  private var inputOffsetY: [CGFloat] { MatrixNamesHelper.parseSizes(control.customFields["matrixInputOffsetY"], count: inputCount, fallback: 0) }
  private var outputOffsetX: [CGFloat] { MatrixNamesHelper.parseSizes(control.customFields["matrixOutputOffsetX"], count: outputCount, fallback: 0) }
  private var outputOffsetY: [CGFloat] { MatrixNamesHelper.parseSizes(control.customFields["matrixOutputOffsetY"], count: outputCount, fallback: 0) }

  private var inputNames: [String] {
    MatrixNamesHelper.parseNames(control.customFields["matrixInputNames"], count: inputCount, prefix: control.customFields["matrixInputPrefix"] ?? "IN")
  }
  private var outputNames: [String] {
    MatrixNamesHelper.parseNames(control.customFields["matrixOutputNames"], count: outputCount, prefix: control.customFields["matrixOutputPrefix"] ?? "OUT")
  }
  private var inputCmds: [String] {
    MatrixNamesHelper.parseCmds(control.customFields["matrixInputCmds"], count: inputCount, idPrefix: control.customFields["matrixInputPrefix"] ?? "IN")
  }
  private var outputCmds: [String] {
    MatrixNamesHelper.parseCmds(control.customFields["matrixOutputCmds"], count: outputCount, idPrefix: control.customFields["matrixOutputPrefix"] ?? "OUT")
  }
  private var inputAccent: Color {
    MatrixNamesHelper.parseColor(control.customFields["matrixInputColor"] ?? "blue")
  }
  private var outputAccent: Color {
    MatrixNamesHelper.parseColor(control.customFields["matrixOutputColor"] ?? "green")
  }
  private var chipTextColor: Color {
    MatrixNamesHelper.parseColor(control.customFields["matrixTextColor"] ?? "white")
  }
  private var dragAccent: Color {
    MatrixNamesHelper.matrixDragColor(in: control.customFields, fallback: inputAccent)
  }
  private func chipBorderColor(accent: Color, emphasized: Bool) -> Color {
    MatrixNamesHelper.matrixBorderColor(in: control.customFields, accent: accent, emphasized: emphasized)
  }

  var body: some View {
    GeometryReader { geo in
      let scale = fittedScale(in: geo.size)
      ZStack(alignment: .topLeading) {
        VStack(spacing: 0) {
          outputSection(scale: scale)
          Spacer(minLength: sectionSpacing)
          inputSection(scale: scale)
        }
        .padding(8)

        if isDragging, let srcIdx = dragSourceInput {
          let ew = inputWidths[srcIdx] * scale.w
          let eh = inputHeights[srcIdx] * scale.h
          ghostChip(index: srcIdx, chipW: ew, chipH: eh)
            .scaleEffect(isMerging ? mergeScale : 1.0, anchor: .center)
            .opacity(isMerging ? mergeOpacity : 1.0)
            .position(x: dragPosition.x, y: dragPosition.y)
            .allowsHitTesting(false)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            .zIndex(10)
        }
      }
      .coordinateSpace(name: "matrixTile")
      .onPreferenceChange(ChipFrameKey.self) { chipFrames = $0 }
      .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isDragging)
      .onAppear {
        seedDefaultRoutesIfNeeded()
      }
    }
  }

  private func seedDefaultRoutesIfNeeded() {
    guard runtimeStore.allRoutes(parentID: control.id, outputCount: outputCount).isEmpty else { return }
    for i in 0..<min(inputCount, outputCount) {
      runtimeStore.setRoutedInput(i, parentID: control.id, outputIndex: i)
    }
  }

  private func routedInput(for outputIndex: Int) -> Int? {
    runtimeStore.routedInput(parentID: control.id, outputIndex: outputIndex)
  }

  private func isTapSelectedInput(_ index: Int) -> Bool {
    selectedInput?.parentID == control.id && selectedInput?.index == index
  }

  private func isSelectionBlocked(forOutput output: Int) -> Bool {
    guard let sel = selectedInput, sel.parentID == control.id else { return false }
    return MatrixNamesHelper.isRoutingBlocked(
      input: sel.index, output: output, customFields: control.customFields, isLive: false)
  }

  private func handleInputTap(_ index: Int) {
    guard !isDragging else { return }
    if isTapSelectedInput(index) {
      selectedInput = nil
    } else {
      selectedInput = SelectedMatrixInput(
        parentID: control.id, index: index, cmd: inputCmds[index])
    }
    runtimeStore.triggerHaptic(.light)
  }

  private func handleOutputTap(_ index: Int) {
    guard !isDragging else { return }
    guard let sel = selectedInput, sel.parentID == control.id else {
      runtimeStore.triggerHaptic(.light)
      return
    }
    let blocked = MatrixNamesHelper.blockedInputs(
      forOutput: index, customFields: control.customFields, isLive: false)
    if blocked.contains(sel.index) {
      blockedOutput = index
      withAnimation(.linear(duration: 0.4)) { blockedShakeCounter += 1 }
      runtimeStore.triggerErrorHaptic()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { blockedOutput = nil }
      return
    }
    performRoute(input: sel.index, output: index)
  }

  // MARK: - Effective chip dimensions (scale factor)

  private struct ChipScale { var w: CGFloat; var h: CGFloat }

  private func fittedScale(in totalSize: CGSize) -> ChipScale {
    let allWidths = inputWidths + outputWidths
    let n = CGFloat(max(inputCount, outputCount, 1))
    let totalChipW = allWidths.prefix(max(inputCount, outputCount)).reduce(0, +)
    let available = totalSize.width - 16
    let needed = totalChipW + chipSpacing * (n - 1)
    let wScale: CGFloat = needed > available ? available / needed : 1.0

    let titleRowH: CGFloat = titleFontSize + 8
    let labelRowH: CGFloat = chipLabelFontSize * 1.4 + 3
    let overhead = 16 + titleRowH * 2 + titleChipSpacing * 2 + sectionSpacing + labelRowH
    let availH = (totalSize.height - overhead) / 2
    let maxH = (inputHeights + outputHeights).max() ?? chipH
    let hScale: CGFloat = maxH > availH ? availH / maxH : 1.0

    return ChipScale(w: max(wScale, 0.2), h: max(hScale, 0.2))
  }

  // MARK: - Output Section (Displays — top row)

  private var chipLabelFontSize: CGFloat { max(chipFontSize * 1.05, 9) }

  private func outputSection(scale: ChipScale) -> some View {
    VStack(alignment: .center, spacing: titleChipSpacing) {
      HStack(spacing: 8) {
        Image(systemName: "display")
          .font(.system(size: max(titleFontSize - 1, 8), weight: .medium))
          .foregroundStyle(theme.iconColor)
        Text(L10n.matrixDisplays)
          .font(.system(size: titleFontSize, weight: .medium))
          .foregroundStyle(theme.textColor.opacity(0.65))
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: chipSpacing) {
          Spacer(minLength: 0)
          ForEach(0..<outputCount, id: \.self) { i in
            let cw = outputWidths[i] * scale.w
            let ch = outputHeights[i] * scale.h
            VStack(alignment: .center, spacing: 3) {
              outputChip(index: i, chipW: cw, chipH: ch)
              Text(outputNames[i])
                .font(.system(size: chipLabelFontSize, weight: .medium))
                .foregroundStyle(chipTextColor.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: cw, height: chipLabelFontSize * 1.4, alignment: .center)
            }
            .offset(x: outputOffsetX[i] * scale.w, y: outputOffsetY[i] * scale.h)
          }
          Spacer(minLength: 0)
        }
      }
      .scrollClipDisabled(true)
    }
    .frame(maxWidth: .infinity)
  }

  @ViewBuilder
  private func outputChip(index: Int, chipW cw: CGFloat, chipH ch: CGFloat) -> some View {
    let hiddenForDrag: Bool = {
      guard let src = dragSourceInput else { return false }
      return MatrixNamesHelper.isRoutingBlocked(
        input: src, output: index, customFields: control.customFields, isLive: false)
    }()

    if hiddenForDrag {
      Color.clear
        .frame(width: cw, height: ch)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    } else {
      outputChipBody(index: index, chipW: cw, chipH: ch)
    }
  }

  @ViewBuilder
  private func outputChipBody(index: Int, chipW cw: CGFloat, chipH ch: CGFloat) -> some View {
    let isHighlighted = highlightedOutput == index
    let isBusy = sendingRoute == "\(index)"
    let isBlocked = blockedOutput == index
    let isTapBlocked = isSelectionBlocked(forOutput: index)
    let isAwaitingOutput = selectedInput?.parentID == control.id
    let routedInput = routedInput(for: index)
    let hasRoute = routedInput != nil

    let accent = outputAccent
    let chipBg: Color = {
      if isBlocked { return Color.red.opacity(0.18) }
      if isBusy { return accent.opacity(0.50) }
      if isHighlighted { return dragAccent.opacity(0.65) }
      if isAwaitingOutput && !isTapBlocked { return accent.opacity(0.38) }
      if hasRoute { return accent.opacity(0.45) }
      return accent.opacity(0.28)
    }()
    let borderColor: Color = {
      if isBlocked || isTapBlocked { return .red.opacity(isTapBlocked ? 0.6 : 1) }
      if isBusy { return .orange.opacity(0.6) }
      if isHighlighted { return dragAccent }
      if isAwaitingOutput { return chipBorderColor(accent: accent, emphasized: true) }
      if hasRoute { return chipBorderColor(accent: accent, emphasized: true) }
      return chipBorderColor(accent: accent, emphasized: false)
    }()
    let borderWidth: CGFloat = (isHighlighted || isBusy || hasRoute || isBlocked) ? 2.0 : 1.5
    let iconSz = max(min(chipFontSize - 4, cw * 0.35), 8)
    let srcTextSz = max(min(chipFontSize * 0.60, cw * 0.28), 6)

    // Always reserve space for the source-name row so the icon stays
    // at the same vertical position across all chips regardless of routing state.
    VStack(spacing: 2) {
      Image(systemName: "display")
        .font(.system(size: iconSz, weight: .medium))
        .foregroundStyle(hasRoute ? chipTextColor : chipTextColor.opacity(0.65))
      Text(routedInput != nil ? inputNames[routedInput!] : " ")
        .font(.system(size: srcTextSz, weight: chipFontWeight))
        .foregroundStyle(chipTextColor)
        .opacity(routedInput != nil ? 1 : 0)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .transition(.scale(scale: 0.7).combined(with: .opacity))
    }
    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: routedInput)
    .padding(.horizontal, max(cw * 0.12, 5))
    .padding(.vertical, max(ch * 0.12, 5))
    .frame(width: cw, height: ch)
    .background(chipBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .shadow(color: .black.opacity(0.35), radius: styles.shadowBlur, x: 0, y: styles.shadowY)
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(borderColor, lineWidth: borderWidth)
        .shadow(
          color: isHighlighted ? dragAccent.opacity(styles.glowOpacity) : .clear,
          radius: 8
        )
    }
    .scaleEffect(isHighlighted ? 1.04 : 1.0)
    .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isHighlighted)
    .modifier(ShakeEffect(animatableData: isBlocked ? blockedShakeCounter : 0))
    .overlay {
      if isTapBlocked && isAwaitingOutput {
        VStack {
          HStack {
            Spacer()
            Image(systemName: "lock.slash.fill")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(.red)
              .padding(4)
          }
          Spacer()
        }
      }
    }
    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .onTapGesture { handleOutputTap(index) }
    .background(
      GeometryReader { g in
        Color.clear.preference(
          key: ChipFrameKey.self,
          value: [chipKey("out", index): g.frame(in: .named("matrixTile"))]
        )
      }
    )
  }

  // MARK: - Input Section (Video Sources — bottom row)

  private func inputSection(scale: ChipScale) -> some View {
    VStack(alignment: .center, spacing: titleChipSpacing) {
      HStack(spacing: 8) {
        Image(systemName: "video.fill")
          .font(.system(size: max(titleFontSize - 1, 8), weight: .medium))
          .foregroundStyle(theme.iconColor)
        Text(L10n.matrixVideoSources)
          .font(.system(size: titleFontSize, weight: .medium))
          .foregroundStyle(theme.textColor.opacity(0.65))
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: chipSpacing) {
          Spacer(minLength: 0)
          ForEach(0..<inputCount, id: \.self) { i in
            inputChip(index: i, chipW: inputWidths[i] * scale.w, chipH: inputHeights[i] * scale.h)
              .offset(x: inputOffsetX[i] * scale.w, y: inputOffsetY[i] * scale.h)
          }
          Spacer(minLength: 0)
        }
      }
      .scrollClipDisabled(true)
    }
    .frame(maxWidth: .infinity)
  }

  private func inputChip(index: Int, chipW cw: CGFloat, chipH ch: CGFloat) -> some View {
    let isDragSource = dragSourceInput == index
    let isTapSelected = isTapSelectedInput(index)
    let isActive = isDragSource || isTapSelected
    let accent = inputAccent
    let chipBg = (isDragSource && isDragging) ? dragAccent.opacity(0.60)
      : (isActive ? accent.opacity(0.60) : accent.opacity(0.30))
    let borderColor: Color = (isDragSource && isDragging) ? dragAccent
      : chipBorderColor(accent: accent, emphasized: isActive)
    let borderWidth: CGFloat = isActive ? 2.0 : 1.5
    let iconSz = max(min(chipFontSize - 4, cw * 0.35), 8)
    let textSz = max(min(chipFontSize * 0.85, cw * 0.3), 8)

    return VStack(spacing: 2) {
      Image(systemName: "video.fill")
        .font(.system(size: iconSz, weight: .medium))
        .foregroundStyle(chipTextColor)
      Text(inputNames[index])
        .font(.system(size: textSz, weight: chipFontWeight))
        .foregroundStyle(chipTextColor)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }
    .padding(.horizontal, max(cw * 0.12, 5))
    .padding(.vertical, max(ch * 0.12, 5))
    .frame(width: cw, height: ch)
    .background(chipBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .shadow(color: .black.opacity(0.35), radius: styles.shadowBlur, x: 0, y: styles.shadowY)
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(borderColor, lineWidth: borderWidth)
        .shadow(
          color: (isDragSource && isDragging) ? dragAccent.opacity(styles.glowOpacity)
            : (isActive ? accent.opacity(styles.glowOpacity) : .clear),
          radius: 8
        )
    }
    .scaleEffect(isDragSource && isDragging ? 0.88 : (isActive ? 1.04 : 1.0))
    .opacity(isDragSource && isDragging ? 0.35 : 1.0)
    .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isActive)
    .animation(.spring(response: 0.2,  dampingFraction: 0.7),  value: isDragging)
    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .onTapGesture { handleInputTap(index) }
    .background(
      GeometryReader { g in
        Color.clear.preference(
          key: ChipFrameKey.self,
          value: [chipKey("in", index): g.frame(in: .named("matrixTile"))]
        )
      }
    )
    .gesture(
      DragGesture(minimumDistance: 12, coordinateSpace: .named("matrixTile"))
        .onChanged { value in
          if !isDragging {
            if selectedInput?.parentID == control.id { selectedInput = nil }
            dragSourceInput = index
            isDragging = true
            runtimeStore.triggerHaptic(.light)
          }
          dragPosition = value.location
          highlightedOutput = outputAtPosition(value.location)
        }
        .onEnded { value in
          let outIdx    = outputAtPosition(value.location)
          let srcInput  = dragSourceInput

          if let outIdx, let srcInput,
             let targetFrame = chipFrames[chipKey("out", outIdx)] {
            // ── Merge animation ──────────────────────────────────────
            let targetCenter = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
            isMerging   = true
            mergeScale  = 1.0
            mergeOpacity = 1.0

            // Phase 1: snap ghost to output chip centre
            withAnimation(.spring(response: 0.16, dampingFraction: 0.78)) {
              dragPosition      = targetCenter
              highlightedOutput = nil
            }

            // Phase 2: shrink + fade into the chip
            Task { @MainActor in
              try? await Task.sleep(nanoseconds: 120_000_000) // 0.12 s
              withAnimation(.easeIn(duration: 0.42)) {
                mergeScale   = 0.05
                mergeOpacity = 0.0
              }
              try? await Task.sleep(nanoseconds: 430_000_000) // 0.43 s
              isDragging        = false
              isMerging         = false
              dragSourceInput   = nil
              mergeScale        = 1.0
              mergeOpacity      = 1.0
            }

            performRoute(input: srcInput, output: outIdx)

          } else {
            // No valid target — cancel normally
            if let outIdx, let srcInput { performRoute(input: srcInput, output: outIdx) }
            isDragging        = false
            dragSourceInput   = nil
            highlightedOutput = nil
          }
        }
    )
  }

  // MARK: - Ghost chip (follows finger during drag)

  private func ghostChip(index: Int, chipW cw: CGFloat, chipH ch: CGFloat) -> some View {
    let iconSz = max(min(chipFontSize - 4, cw * 0.35), 8)
    let textSz = max(min(chipFontSize * 0.85, cw * 0.3), 8)
    let targetIdx = highlightedOutput
    let accent = inputAccent
    let dragColor = dragAccent

    return VStack(spacing: 2) {
      Image(systemName: "video.fill")
        .font(.system(size: iconSz, weight: .medium))
        .foregroundStyle(chipTextColor)
      Text(inputNames[index])
        .font(.system(size: textSz, weight: chipFontWeight))
        .foregroundStyle(chipTextColor)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
      // Show target name when hovering over an output
      if let t = targetIdx {
        Image(systemName: "arrow.up")
          .font(.system(size: max(iconSz - 2, 6), weight: .bold))
          .foregroundStyle(dragColor)
        Text(outputNames[t])
          .font(.system(size: max(textSz - 1, 6), weight: .bold))
          .foregroundStyle(dragColor)
          .lineLimit(1)
          .minimumScaleFactor(0.5)
      }
    }
    .padding(.horizontal, max(cw * 0.12, 5))
    .padding(.vertical, max(ch * 0.10, 4))
    .frame(width: cw, height: ch)
    .background(
      dragColor.opacity(0.75),
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(
          targetIdx != nil ? dragColor : chipBorderColor(accent: accent, emphasized: true),
          lineWidth: targetIdx != nil ? 2.5 : 1.5
        )
    }
    .shadow(
      color: targetIdx != nil
        ? dragColor.opacity(0.55)
        : .black.opacity(0.45),
      radius: targetIdx != nil ? 14 : 8
    )
    .scaleEffect(targetIdx != nil ? 1.12 : 1.05)
    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: targetIdx)
  }

  // MARK: - Helpers

  private func chipKey(_ type: String, _ index: Int) -> String { "\(type)_\(index)" }

  private func outputAtPosition(_ point: CGPoint) -> Int? {
    for i in 0..<outputCount {
      if let src = dragSourceInput,
         MatrixNamesHelper.isRoutingBlocked(
           input: src, output: i, customFields: control.customFields, isLive: false) {
        continue
      }
      if let frame = chipFrames[chipKey("out", i)],
        frame.insetBy(dx: -10, dy: -10).contains(point)
      {
        return i
      }
    }
    return nil
  }

  private func performRoute(input: Int, output: Int) {
    print("[Matrix] performRoute input=\(input) output=\(output)  bindingDeviceID=\(control.binding?.deviceID.uuidString ?? "nil")")

    // Blacklist check
    let blocked = MatrixNamesHelper.blockedInputs(forOutput: output, customFields: control.customFields, isLive: false)
    if blocked.contains(input) {
      runtimeStore.triggerErrorHaptic()
      blockedOutput = output
      withAnimation(.linear(duration: 0.4)) { blockedShakeCounter += 1 }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { blockedOutput = nil }
      return
    }

    guard let dev = device else {
      print("[Matrix] ❌ device is nil — binding not matched in devices list")
      runtimeStore.triggerErrorHaptic()
      OperationLogStore.shared.append(controlTitle: control.title, commandName: "Route failed", payload: template, deviceName: "—", deviceHost: "—")
      OperationLogStore.shared.markLastResult(.failure("Device not bound – check binding in Editor"))
      return
    }

    print("[Matrix] Device found: \(dev.name) → \(dev.host):\(dev.port)")
    runtimeStore.triggerHaptic(.medium)
    sendingRoute = "\(output)"

    let previousInput = routedInput(for: output)
    routeGenerationCounter += 1
    let generation = routeGenerationCounter
    routeGenerations[output] = generation
    runtimeStore.setRoutedInput(input, parentID: control.id, outputIndex: output)

    let inputCmd = inputCmds[input]
    let outputCmd = outputCmds[output]
    let payload = template
      .replacingOccurrences(of: "{input}", with: inputCmd)
      .replacingOccurrences(of: "{output}", with: outputCmd)

    print("[Matrix] Sending payload: \"\(payload)\"")
    OperationLogStore.shared.append(
      controlTitle: control.title,
      commandName: "\(inputNames[input]) → \(outputNames[output])",
      payload: payload, deviceName: dev.name, deviceHost: dev.host
    )

    Task {
      do {
        try await transport.sendRaw(
          device: dev, payload: payload,
          lineEnding: lineEnding, timeoutMs: timeoutMs
        )
        await MainActor.run {
          guard routeGenerations[output] == generation else { return }
          sendingRoute = nil
          runtimeStore.triggerHaptic(.rigid)
          OperationLogStore.shared.markLastResult(.success)
        }
      } catch {
        await MainActor.run {
          guard routeGenerations[output] == generation else { return }
          sendingRoute = nil
          if let previousInput {
            runtimeStore.setRoutedInput(previousInput, parentID: control.id, outputIndex: output)
          }
          runtimeStore.triggerErrorHaptic()
          OperationLogStore.shared.markLastResult(.failure(error.localizedDescription))
        }
      }
    }
  }

  private func matrixParseFontWeight(_ value: String) -> Font.Weight {
    switch value {
    case "regular": return .regular
    case "medium": return .medium
    case "bold": return .bold
    default: return .semibold
    }
  }
}

enum MatrixNamesHelper {
  static func parseColor(_ value: String) -> Color {
    if value.hasPrefix("#") { return Color(hexString: value) }
    switch value {
    case "black": return .black
    case "gray": return .gray
    case "blue": return .blue
    case "green": return .green
    case "orange": return .orange
    case "red": return .red
    case "cyan": return .cyan
    case "yellow": return .yellow
    case "purple": return .purple
    case "pink": return .pink
    case "mint": return .mint
    case "teal": return .teal
    default: return .white
    }
  }

  static func optionalMatrixColor(_ fields: [String: String], key: String) -> Color? {
    guard let raw = fields[key], !raw.isEmpty else { return nil }
    return parseColor(raw)
  }

  static func matrixDragColor(in fields: [String: String], fallback: Color) -> Color {
    optionalMatrixColor(fields, key: "matrixDragColor") ?? fallback
  }

  static func matrixBorderColor(in fields: [String: String], accent: Color, emphasized: Bool) -> Color {
    if let border = optionalMatrixColor(fields, key: "matrixBorderColor") {
      return emphasized ? border : border.opacity(0.65)
    }
    return emphasized ? accent : accent.opacity(0.55)
  }

  static func parseNames(_ json: String?, count: Int, prefix: String) -> [String] {
    if let json, let data = json.data(using: .utf8),
      let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
    {
      var result = arr
      while result.count < count { result.append("\(prefix)\(result.count + 1)") }
      return Array(result.prefix(count))
    }
    return (1...count).map { "\(prefix)\($0)" }
  }

  static func parseCmds(_ json: String?, count: Int, idPrefix: String? = nil) -> [String] {
    func defaultCmd(at index: Int) -> String {
      if let idPrefix { return "\(idPrefix)\(index + 1)" }
      return "\(index + 1)"
    }
    if let json, let data = json.data(using: .utf8),
      let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
    {
      var result = arr
      while result.count < count { result.append(defaultCmd(at: result.count)) }
      return Array(result.prefix(count))
    }
    return (0..<count).map { defaultCmd(at: $0) }
  }

  /// Parses a JSON array of doubles for per-chip sizes. Returns an array of
  /// `count` elements; missing entries fall back to `fallback`.
  static func parseSizes(_ json: String?, count: Int, fallback: CGFloat) -> [CGFloat] {
    if let json, let data = json.data(using: .utf8),
       let arr = try? JSONSerialization.jsonObject(with: data) as? [Double]
    {
      var result = arr.map { CGFloat($0) }
      while result.count < count { result.append(fallback) }
      return Array(result.prefix(count))
    }
    return Array(repeating: fallback, count: count)
  }

  /// Encodes an array of CGFloat values to a JSON string for storage.
  static func encodeSizes(_ sizes: [CGFloat]) -> String {
    let ints = sizes.map { Int($0) }
    if let data = try? JSONSerialization.data(withJSONObject: ints),
       let str = String(data: data, encoding: .utf8) {
      return str
    }
    return "[]"
  }

  /// Returns the set of blocked input indices for a given output index.
  /// Stored as JSON: `{"0":[1,3],"2":[0,2]}` in `matrixOutputBlockedInputs`
  /// or `liveMatrixOutputBlockedInputs`.
  static func blockedInputs(
    forOutput outputIndex: Int,
    customFields: [String: String],
    isLive: Bool
  ) -> Set<Int> {
    let key = isLive ? "liveMatrixOutputBlockedInputs" : "matrixOutputBlockedInputs"
    guard let raw = customFields[key],
          let data = raw.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [Int]],
          let arr = dict["\(outputIndex)"]
    else { return [] }
    return Set(arr)
  }

  static func isRoutingBlocked(
    input: Int, output: Int, customFields: [String: String], isLive: Bool
  ) -> Bool {
    blockedInputs(forOutput: output, customFields: customFields, isLive: isLive).contains(input)
  }

  /// Updates the blocked-inputs JSON stored in `customFields` for a given output index.
  /// Returns the updated JSON string (or nil on encoding failure).
  static func setBlockedInputs(
    _ blocked: Set<Int>,
    forOutput outputIndex: Int,
    existing customFields: [String: String],
    isLive: Bool
  ) -> String {
    let key = isLive ? "liveMatrixOutputBlockedInputs" : "matrixOutputBlockedInputs"
    var dict: [String: [Int]] = {
      guard let raw = customFields[key], let data = raw.data(using: .utf8) else { return [:] }
      return (try? JSONSerialization.jsonObject(with: data) as? [String: [Int]]) ?? [:]
    }()
    dict["\(outputIndex)"] = Array(blocked).sorted()
    if let data = try? JSONSerialization.data(withJSONObject: dict),
       let str = String(data: data, encoding: .utf8) { return str }
    return customFields[key] ?? "{}"
  }
}

// MARK: - Live Matrix Tile View

private struct LiveMatrixTileView: View {
  let control: ControlItem
  let device: DeviceItem?
  let transport: TcpTransport
  @ObservedObject var runtimeStore: RuntimeControlStore
  let styles: StyleItem
  let theme: ThemeColors
  var tileSize: CGSize = CGSize(width: 400, height: 300)
  @Environment(\.scenePhase) private var scenePhase

  @State private var dragSourceInput: Int?
  @State private var dragPosition: CGPoint = .zero
  @State private var isDragging = false
  @State private var highlightedOutput: Int?
  @State private var chipFrames: [String: CGRect] = [:]
  @State private var sendingRoute: String?
  @State private var routeGenerations: [Int: UInt64] = [:]
  @State private var routeGenerationCounter: UInt64 = 0
  @State private var isMerging = false
  @State private var mergeScale: CGFloat = 1.0
  @State private var mergeOpacity: Double = 1.0
  /// Output chip playing the "land" spring-pop animation (由大到小渐入)
  @State private var mergingOutputIndex: Int? = nil
  @State private var mergeOutputScale: CGFloat = 1.28
  /// Output chip that was just blocked (drives shake animation)
  @State private var blockedOutput: Int? = nil
  @State private var blockedShakeCounter: CGFloat = 0
  @EnvironmentObject private var streamHub: MJPEGStreamHub
  @StateObject private var hpdMonitor = HPDMonitor()

  // MARK: - Parsed customFields

  /// "horizontal" (default: sources left, displays right) or "vertical" (displays top, sources bottom)
  private var isVerticalLayout: Bool { (control.customFields["liveMatrixLayout"] ?? "horizontal") == "vertical" }

  private var inputCount: Int { Int(control.customFields["liveMatrixInputCount"] ?? "") ?? 4 }
  private var outputCount: Int { Int(control.customFields["liveMatrixOutputCount"] ?? "") ?? 4 }
  private var template: String { control.customFields["liveMatrixCommandTemplate"] ?? "matrix aset :av {input} {output}" }
  private var lineEnding: LineEnding { LineEnding(rawValue: control.customFields["liveMatrixLineEnding"] ?? "crlf") ?? .crlf }
  private var timeoutMs: Int { Int(control.customFields["liveMatrixTimeoutMs"] ?? "") ?? 1500 }
  private var chipW: CGFloat { CGFloat(Double(control.customFields["liveMatrixChipWidth"] ?? "") ?? 160) }
  private var chipH: CGFloat { CGFloat(Double(control.customFields["liveMatrixChipHeight"] ?? "") ?? 120) }
  private var outputChipW: CGFloat { CGFloat(Double(control.customFields["liveMatrixOutputChipWidth"] ?? "") ?? Double(chipW)) }
  private var outputChipH: CGFloat { CGFloat(Double(control.customFields["liveMatrixOutputChipHeight"] ?? "") ?? Double(chipH)) }
  private var chipFontSize: CGFloat { CGFloat(Double(control.customFields["liveMatrixFontSize"] ?? "") ?? 12) }
  private var chipFontWeight: Font.Weight { lmParseFontWeight(control.customFields["liveMatrixFontWeight"] ?? "semibold") }
  private var titleFontSize: CGFloat { CGFloat(Double(control.customFields["liveMatrixTitleFontSize"] ?? "") ?? 12) }
  private var chipSpacing: CGFloat { CGFloat(Double(control.customFields["liveMatrixChipSpacing"] ?? "") ?? 8) }
  private var titleChipSpacing: CGFloat { CGFloat(Double(control.customFields["liveMatrixTitleChipSpacing"] ?? "") ?? 8) }

  private var perInputWidths: [CGFloat] { MatrixNamesHelper.parseSizes(control.customFields["liveMatrixInputWidths"], count: inputCount, fallback: chipW) }
  private var perInputHeights: [CGFloat] { MatrixNamesHelper.parseSizes(control.customFields["liveMatrixInputHeights"], count: inputCount, fallback: chipH) }
  private var perOutputWidths: [CGFloat] { MatrixNamesHelper.parseSizes(control.customFields["liveMatrixOutputWidths"], count: outputCount, fallback: outputChipW) }
  private var perOutputHeights: [CGFloat] { MatrixNamesHelper.parseSizes(control.customFields["liveMatrixOutputHeights"], count: outputCount, fallback: outputChipH) }

  private var perInputOffsetX: [CGFloat] { MatrixNamesHelper.parseSizes(control.customFields["liveMatrixInputOffsetX"], count: inputCount, fallback: 0) }
  private var perInputOffsetY: [CGFloat] { MatrixNamesHelper.parseSizes(control.customFields["liveMatrixInputOffsetY"], count: inputCount, fallback: 0) }
  private var perOutputOffsetX: [CGFloat] { MatrixNamesHelper.parseSizes(control.customFields["liveMatrixOutputOffsetX"], count: outputCount, fallback: 0) }
  private var perOutputOffsetY: [CGFloat] { MatrixNamesHelper.parseSizes(control.customFields["liveMatrixOutputOffsetY"], count: outputCount, fallback: 0) }

  private var streamServerHost: String { control.customFields["liveMatrixStreamServerHost"] ?? "" }
  private var streamServerPort: String { control.customFields["liveMatrixStreamServerPort"] ?? "" }
  private var streamWidth: String { control.customFields["liveMatrixStreamWidth"] ?? "960" }
  private var streamHeight: String { control.customFields["liveMatrixStreamHeight"] ?? "540" }
  private var streamFps: String { control.customFields["liveMatrixStreamFps"] ?? "30" }
  private var streamBw: String { control.customFields["liveMatrixStreamBw"] ?? "8000" }
  private var streamAs: String { control.customFields["liveMatrixStreamAs"] ?? "0" }

  private var inputNames: [String] {
    MatrixNamesHelper.parseNames(control.customFields["liveMatrixInputNames"], count: inputCount, prefix: control.customFields["liveMatrixInputPrefix"] ?? "Tx")
  }
  private var outputNames: [String] {
    MatrixNamesHelper.parseNames(control.customFields["liveMatrixOutputNames"], count: outputCount, prefix: control.customFields["liveMatrixOutputPrefix"] ?? "Rx")
  }
  private var inputCmds: [String] {
    MatrixNamesHelper.parseCmds(control.customFields["liveMatrixInputCmds"], count: inputCount)
  }
  private var outputCmds: [String] {
    MatrixNamesHelper.parseCmds(control.customFields["liveMatrixOutputCmds"], count: outputCount)
  }

  private func parseJSONStringArray(_ json: String?, count: Int, fallback: String = "") -> [String] {
    if let json, let data = json.data(using: .utf8),
       let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
      var result = arr
      while result.count < count { result.append(fallback) }
      return Array(result.prefix(count))
    }
    return Array(repeating: fallback, count: count)
  }

  private var inputStreamIPs: [String] { parseJSONStringArray(control.customFields["liveMatrixInputStreamIPs"], count: inputCount) }
  private var inputStreamPorts: [String] { parseJSONStringArray(control.customFields["liveMatrixInputStreamPorts"], count: inputCount, fallback: "8080") }
  private var inputStreamDevIDs: [String] { parseJSONStringArray(control.customFields["liveMatrixInputStreamDevIDs"], count: inputCount) }
  private var outputStreamIPs: [String] { parseJSONStringArray(control.customFields["liveMatrixOutputStreamIPs"], count: outputCount) }
  private var outputStreamPorts: [String] { parseJSONStringArray(control.customFields["liveMatrixOutputStreamPorts"], count: outputCount, fallback: "8080") }
  private var outputStreamDevIDs: [String] { parseJSONStringArray(control.customFields["liveMatrixOutputStreamDevIDs"], count: outputCount) }

  private func streamURL(ip: String, port: String, devID: String) -> URL? {
    LiveMatrixStreamURL.build(
      customFields: control.customFields,
      ip: ip,
      port: port,
      devID: devID
    )
  }

  /// Returns `true` when we have explicitly received HPD 0 for this input's devID.
  /// Unknown state (no HPD message yet) is treated as "signal present" to avoid
  /// false "No Signal" on startup.
  private func isInputSignalLost(index: Int) -> Bool {
    let devID = inputStreamDevIDs[index]
    guard !devID.isEmpty else { return false }
    return hpdMonitor.signalState[devID.uppercased()] == false
  }

  // MARK: - Body

  var body: some View {
      let sc = lmFittedScale(in: tileSize)
      ZStack(alignment: .topLeading) {
        if isVerticalLayout {
          VStack(spacing: 0) {
            outputRow(scale: sc)
            Spacer(minLength: 4)
            inputRow(scale: sc)
          }
          .padding(8)
        } else {
          HStack(alignment: .top, spacing: 0) {
            let maxInW = perInputWidths.max() ?? chipW
            let maxOutW = perOutputWidths.max() ?? outputChipW
            inputColumn(scale: sc)
              .frame(width: maxInW * sc.w, alignment: .center)
            Spacer(minLength: 4)
            outputColumn(scale: sc)
              .frame(width: maxOutW * sc.w, alignment: .center)
          }
          .padding(8)
        }

        if isDragging, let srcIdx = dragSourceInput {
          let ew = perInputWidths[srcIdx] * sc.w
          let eh = perInputHeights[srcIdx] * sc.h
          ghostChip(index: srcIdx, chipW: ew, chipH: eh)
            .scaleEffect(isMerging ? mergeScale : 1.0, anchor: .center)
            .opacity(isMerging ? mergeOpacity : 1.0)
            .position(x: dragPosition.x, y: dragPosition.y)
            .allowsHitTesting(false)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            .zIndex(10)
        }
      }
      .coordinateSpace(name: "liveMatrixTile")
      .onPreferenceChange(ChipFrameKey.self) { chipFrames = $0 }
      .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isDragging)
      .onAppear {
        if let device {
          hpdMonitor.start(transport: transport, device: device)
        }
        seedDefaultRoutesIfNeeded()
      }
      .onDisappear {
        hpdMonitor.stop()
      }
      .onChange(of: scenePhase) { _, phase in
        guard phase == .active else { return }
        streamHub.refreshAll()
        if let device {
          hpdMonitor.reconnect(transport: transport, device: device)
        }
      }
  }

  private func seedDefaultRoutesIfNeeded() {
    guard runtimeStore.allRoutes(parentID: control.id, outputCount: outputCount).isEmpty else { return }
    for i in 0..<min(inputCount, outputCount) {
      runtimeStore.setRoutedInput(i, parentID: control.id, outputIndex: i)
    }
  }

  private func routedInput(for outputIndex: Int) -> Int? {
    runtimeStore.routedInput(parentID: control.id, outputIndex: outputIndex)
  }

  // MARK: - Fitted chip scale

  private struct LMChipScale { var w: CGFloat; var h: CGFloat }

  private func lmFittedScale(in totalSize: CGSize) -> LMChipScale {
    let titleRowH: CGFloat = titleFontSize + 8
    let n = CGFloat(max(inputCount, outputCount, 1))

    if isVerticalLayout {
      let availableW = max(totalSize.width - 16, 60)
      let maxInW = perInputWidths.max() ?? chipW
      let maxOutW = perOutputWidths.max() ?? outputChipW
      let maxW = max(maxInW, maxOutW)
      let wScale: CGFloat = maxW > availableW ? availableW / maxW : 1.0

      let halfRow = (totalSize.height - 16 - (titleRowH + titleChipSpacing) * 2 - 4) / 2
      let scrollH = max(halfRow - titleRowH - titleChipSpacing, 40)
      let maxInH = perInputHeights.max() ?? chipH
      let maxOutH = perOutputHeights.max() ?? outputChipH
      let maxH = max(maxInH, maxOutH)
      let hScale: CGFloat = maxH > scrollH ? scrollH / maxH : 1.0

      return LMChipScale(w: max(wScale, 0.2), h: max(hScale, 0.2))
    }

    let availableH = totalSize.height - 16 - titleRowH - titleChipSpacing
    let maxPerChipH = (availableH - chipSpacing * (n - 1)) / n
    let maxH = max(perInputHeights.max() ?? chipH, perOutputHeights.max() ?? outputChipH)
    let hScale: CGFloat = maxH > maxPerChipH ? maxPerChipH / maxH : 1.0

    let gapBetweenColumns: CGFloat = 4
    let innerArea = max(totalSize.width - 16, 120)
    let maxInW = perInputWidths.max() ?? chipW
    let maxOutW = perOutputWidths.max() ?? outputChipW
    let pairSum = maxInW + maxOutW
    let wScale: CGFloat = pairSum > 0 ? min(1, (innerArea - gapBetweenColumns) / pairSum) : 1

    return LMChipScale(w: max(wScale, 0.2), h: max(hScale, 0.2))
  }

  // MARK: - Input Column (Signal Sources — left side)

  private func inputColumn(scale: LMChipScale) -> some View {
    VStack(alignment: .center, spacing: titleChipSpacing) {
      HStack(spacing: 6) {
        Image(systemName: "video.fill")
          .font(.system(size: max(titleFontSize - 1, 8), weight: .medium))
          .foregroundStyle(theme.iconColor)
        Text(L10n.liveMatrixSources)
          .font(.system(size: titleFontSize, weight: .medium))
          .foregroundStyle(theme.textColor.opacity(0.65))
      }
      VStack(spacing: chipSpacing) {
        ForEach(0..<inputCount, id: \.self) { i in
          inputChip(index: i, chipW: perInputWidths[i] * scale.w, chipH: perInputHeights[i] * scale.h)
            .offset(x: perInputOffsetX[i] * scale.w, y: perInputOffsetY[i] * scale.h)
        }
      }
      .frame(maxWidth: .infinity, alignment: .center)
    }
  }

  private func inputChip(index: Int, chipW cw: CGFloat, chipH ch: CGFloat) -> some View {
    let isSource = dragSourceInput == index
    let signalLost = isInputSignalLost(index: index)
    let chipBg = isSource ? theme.activeButtonBg : theme.idleButtonBg
    let borderColor: Color = {
      if signalLost { return .red.opacity(0.6) }
      return isSource ? theme.activeBorder : theme.idleBorder
    }()
    let borderWidth: CGFloat = isSource ? 2.0 : 1.5
    let textSz = max(min(chipFontSize, cw * 0.12), 8)
    let url: URL? = signalLost ? nil : streamURL(ip: inputStreamIPs[index], port: inputStreamPorts[index], devID: inputStreamDevIDs[index])

    return VStack(spacing: 3) {
      ZStack(alignment: .bottomLeading) {
        ZStack {
          SharedMJPEGView(url: url, cornerRadius: 8)
            .frame(width: cw, height: ch)
          if signalLost {
            noSignalOverlay(width: cw, height: ch)
              .transition(.opacity.animation(.easeInOut(duration: 0.35)))
          }
        }
        Text(inputNames[index])
          .font(.system(size: textSz, weight: chipFontWeight))
          .foregroundStyle(.white)
          .lineLimit(1)
          .minimumScaleFactor(0.5)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
          .padding(4)
      }
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .background(chipBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .shadow(color: .black.opacity(0.35), radius: styles.shadowBlur, x: 0, y: styles.shadowY)
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(borderColor, lineWidth: borderWidth)
          .shadow(
            color: isSource ? theme.activeBorder.opacity(styles.glowOpacity) : .clear,
            radius: 8
          )
      }
      .scaleEffect(isSource && isDragging ? 0.88 : (isSource ? 1.04 : 1.0))
      .opacity(isSource && isDragging ? 0.35 : 1.0)
      .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isSource)
      .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isDragging)
    }
    .background(
      GeometryReader { g in
        Color.clear.preference(
          key: ChipFrameKey.self,
          value: [chipKey("in", index): g.frame(in: .named("liveMatrixTile"))]
        )
      }
    )
    .gesture(
      // minimumDistance 14 pt ≈ 5 mm — prevents accidental activation on light taps.
      // Direction guard: only lock in the drag once the finger moves toward the target side
      // (horizontal: rightward; vertical: upward), reducing false triggers from scrolling.
      DragGesture(minimumDistance: 14, coordinateSpace: .named("liveMatrixTile"))
        .onChanged { value in
          // Direction guard: require dominant movement toward the output side.
          let dx = abs(value.translation.width)
          let dy = abs(value.translation.height)
          let intendedDrag: Bool = isVerticalLayout
            ? (dy > dx && value.translation.height < 0)   // vertical: drag upward toward outputs
            : (dx > dy && value.translation.width  > 0)   // horizontal: drag rightward toward outputs
          guard intendedDrag || isDragging else { return }

          if !isDragging {
            dragSourceInput = index
            isDragging = true
            runtimeStore.triggerHaptic(.light)
          }
          dragPosition = value.location
          highlightedOutput = outputAtPosition(value.location)
        }
        .onEnded { value in
          guard isDragging else { return }
          let outIdx = outputAtPosition(value.location)
          let srcInput = dragSourceInput

          if let outIdx, let srcInput,
             let targetFrame = chipFrames[chipKey("out", outIdx)] {
            let targetCenter = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
            isMerging    = true
            mergeScale   = 1.0
            mergeOpacity = 1.0

            // Phase 1: ghost chip flies to output chip center and overlaps it
            withAnimation(.spring(response: 0.16, dampingFraction: 0.78)) {
              dragPosition      = targetCenter
              highlightedOutput = nil
            }

            Task { @MainActor in
              // Wait for ghost to arrive (~120 ms)
              try? await Task.sleep(nanoseconds: 120_000_000)

              // Phase 2a: ghost chip shrinks + fades (absorbed into output)
              withAnimation(.easeIn(duration: 0.30)) {
                mergeScale   = 0.05
                mergeOpacity = 0.0
              }

              // Phase 2b: output chip 由大到小渐入
              // Snap to 1.28x instantly, then spring back to 1.0x
              mergeOutputScale   = 1.28
              mergingOutputIndex = outIdx
              withAnimation(.spring(response: 0.38, dampingFraction: 0.58)) {
                mergeOutputScale = 1.0
              }

              // Wait for ghost shrink to complete (~340 ms)
              try? await Task.sleep(nanoseconds: 340_000_000)
              isDragging      = false
              isMerging       = false
              dragSourceInput = nil
              mergeScale      = 1.0
              mergeOpacity    = 1.0

              // Wait for output spring to settle, then clean up
              try? await Task.sleep(nanoseconds: 280_000_000)
              mergingOutputIndex = nil
              mergeOutputScale   = 1.28
            }

            performRoute(input: srcInput, output: outIdx)
          } else {
            if let outIdx, let srcInput { performRoute(input: srcInput, output: outIdx) }
            isDragging        = false
            dragSourceInput   = nil
            highlightedOutput = nil
          }
        }
    )
  }

  // MARK: - Output Column (Displays — right side, horizontal layout)

  private func outputColumn(scale: LMChipScale) -> some View {
    VStack(alignment: .center, spacing: titleChipSpacing) {
      HStack(spacing: 6) {
        Image(systemName: "display")
          .font(.system(size: max(titleFontSize - 1, 8), weight: .medium))
          .foregroundStyle(theme.iconColor)
        Text(L10n.liveMatrixDisplays)
          .font(.system(size: titleFontSize, weight: .medium))
          .foregroundStyle(theme.textColor.opacity(0.65))
      }
      VStack(spacing: chipSpacing) {
        ForEach(0..<outputCount, id: \.self) { i in
          outputChip(index: i, chipW: perOutputWidths[i] * scale.w, chipH: perOutputHeights[i] * scale.h)
            .offset(x: perOutputOffsetX[i] * scale.w, y: perOutputOffsetY[i] * scale.h)
        }
      }
      .frame(maxWidth: .infinity, alignment: .center)
    }
  }

  // MARK: - Output Row (Displays — top, vertical layout)

  private func outputRow(scale: LMChipScale) -> some View {
    VStack(alignment: .center, spacing: titleChipSpacing) {
      HStack(spacing: 6) {
        Image(systemName: "display")
          .font(.system(size: max(titleFontSize - 1, 8), weight: .medium))
          .foregroundStyle(theme.iconColor)
        Text(L10n.liveMatrixDisplays)
          .font(.system(size: titleFontSize, weight: .medium))
          .foregroundStyle(theme.textColor.opacity(0.65))
      }
      HStack(spacing: chipSpacing) {
        ForEach(0..<outputCount, id: \.self) { i in
          outputChip(index: i, chipW: perOutputWidths[i] * scale.w, chipH: perOutputHeights[i] * scale.h)
            .offset(x: perOutputOffsetX[i] * scale.w, y: perOutputOffsetY[i] * scale.h)
        }
      }
      .frame(maxWidth: .infinity, alignment: .center)
    }
  }

  // MARK: - Input Row (Sources — bottom, vertical layout)

  private func inputRow(scale: LMChipScale) -> some View {
    VStack(alignment: .center, spacing: titleChipSpacing) {
      HStack(spacing: 6) {
        Image(systemName: "video.fill")
          .font(.system(size: max(titleFontSize - 1, 8), weight: .medium))
          .foregroundStyle(theme.iconColor)
        Text(L10n.liveMatrixSources)
          .font(.system(size: titleFontSize, weight: .medium))
          .foregroundStyle(theme.textColor.opacity(0.65))
      }
      HStack(spacing: chipSpacing) {
        ForEach(0..<inputCount, id: \.self) { i in
          inputChip(index: i, chipW: perInputWidths[i] * scale.w, chipH: perInputHeights[i] * scale.h)
            .offset(x: perInputOffsetX[i] * scale.w, y: perInputOffsetY[i] * scale.h)
        }
      }
      .frame(maxWidth: .infinity, alignment: .center)
    }
  }

  @ViewBuilder
  private func outputChip(index: Int, chipW cw: CGFloat, chipH ch: CGFloat) -> some View {
    let hiddenForDrag: Bool = {
      guard let src = dragSourceInput else { return false }
      return MatrixNamesHelper.isRoutingBlocked(
        input: src, output: index, customFields: control.customFields, isLive: true)
    }()

    if hiddenForDrag {
      Color.clear
        .frame(width: cw, height: ch)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    } else {
      liveMatrixOutputChipBody(index: index, chipW: cw, chipH: ch)
    }
  }

  @ViewBuilder
  private func liveMatrixOutputChipBody(index: Int, chipW cw: CGFloat, chipH ch: CGFloat) -> some View {
    let isHighlighted = highlightedOutput == index
    let isBusy = sendingRoute == "\(index)"
    let isBlocked = blockedOutput == index
    let routedInput = routedInput(for: index)
    let hasRoute = routedInput != nil
    let textSz = max(min(chipFontSize, cw * 0.12), 8)
    let srcTextSz = max(min(chipFontSize * 0.75, cw * 0.10), 7)
    let url: URL? = {
      guard let srcIdx = routedInput else { return nil }
      return streamURL(ip: inputStreamIPs[srcIdx], port: inputStreamPorts[srcIdx], devID: inputStreamDevIDs[srcIdx])
    }()

    let chipBgColor: Color = {
      if isBlocked { return Color.red.opacity(0.18) }
      if isBusy { return theme.idleButtonBg.opacity(0.8) }
      if isHighlighted { return theme.activeButtonBg }
      if hasRoute { return theme.activeButtonBg.opacity(0.55) }
      return theme.idleButtonBg
    }()
    let borderColor: Color = {
      if isBlocked { return .red }
      if isBusy { return .orange.opacity(0.6) }
      if isHighlighted { return theme.activeBorder }
      if hasRoute { return theme.activeBorder.opacity(0.6) }
      return theme.idleBorder
    }()
    let borderW: CGFloat = (isHighlighted || isBusy || hasRoute || isBlocked) ? 2.0 : 1.5

    VStack(spacing: 3) {
      ZStack(alignment: .bottom) {
        SharedMJPEGView(url: url, cornerRadius: 8)
          .frame(width: cw, height: ch)

        HStack(spacing: 4) {
          Text(outputNames[index])
            .font(.system(size: textSz, weight: chipFontWeight))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
          if let routedInput {
            Text("← \(inputNames[routedInput])")
              .font(.system(size: srcTextSz, weight: .medium))
              .foregroundStyle(theme.activeBorder)
              .lineLimit(1)
              .minimumScaleFactor(0.5)
              .transition(.scale(scale: 0.7).combined(with: .opacity))
          }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: routedInput)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .padding(4)
      }
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .background(chipBgColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .shadow(color: .black.opacity(0.35), radius: styles.shadowBlur, x: 0, y: styles.shadowY)
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(borderColor, lineWidth: borderW)
          .shadow(
            color: isHighlighted ? theme.activeBorder.opacity(styles.glowOpacity) : .clear,
            radius: 8
          )
      }
      .scaleEffect(
        mergingOutputIndex == index
          ? mergeOutputScale
          : (isHighlighted ? 1.04 : 1.0)
      )
      .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isHighlighted)
      .animation(.spring(response: 0.38, dampingFraction: 0.58), value: mergeOutputScale)
      .modifier(ShakeEffect(animatableData: isBlocked ? blockedShakeCounter : 0))
    }
    .background(
      GeometryReader { g in
        Color.clear.preference(
          key: ChipFrameKey.self,
          value: [chipKey("out", index): g.frame(in: .named("liveMatrixTile"))]
        )
      }
    )
  }

  // MARK: - Ghost chip

  private func ghostChip(index: Int, chipW cw: CGFloat, chipH ch: CGFloat) -> some View {
    let textSz = max(min(chipFontSize, cw * 0.12), 8)
    let targetIdx = highlightedOutput

    return ZStack {
      Image(systemName: "video.fill")
        .font(.system(size: max(min(cw * 0.18, ch * 0.25), 12), weight: .medium))
        .foregroundStyle(theme.textColor.opacity(0.6))

      VStack {
        Spacer()
        HStack {
          Text(inputNames[index])
            .font(.system(size: textSz, weight: chipFontWeight))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
          Spacer()
        }
        .padding(4)
      }

      if let t = targetIdx {
        VStack {
          HStack {
            Spacer()
            HStack(spacing: 3) {
              Image(systemName: isVerticalLayout ? "arrow.up" : "arrow.right")
                .font(.system(size: max(textSz - 2, 6), weight: .bold))
              Text(outputNames[t])
                .font(.system(size: max(textSz - 1, 6), weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            }
            .foregroundStyle(theme.activeBorder)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
          }
          .padding(4)
          Spacer()
        }
      }
    }
    .frame(width: cw, height: ch)
    .background(
      theme.activeButtonBg.opacity(0.92),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(
          targetIdx != nil ? theme.activeBorder : theme.idleBorder,
          lineWidth: targetIdx != nil ? 2.5 : 1.5
        )
    }
    .shadow(
      color: targetIdx != nil ? theme.activeBorder.opacity(0.55) : .black.opacity(0.45),
      radius: targetIdx != nil ? 14 : 8
    )
    .scaleEffect(targetIdx != nil ? 1.06 : 1.0)
    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: targetIdx)
  }

  // MARK: - No Signal Overlay

  private func noSignalOverlay(width: CGFloat, height: CGFloat) -> some View {
    ZStack {
      Color.black.opacity(0.78)
      VStack(spacing: 6) {
        Image(systemName: "antenna.radiowaves.left.and.right.slash")
          .font(.system(size: max(min(width * 0.14, height * 0.22), 14), weight: .medium))
          .foregroundStyle(.red.opacity(0.85))
        Text("No Signal")
          .font(.system(size: max(min(width * 0.08, height * 0.10), 9), weight: .semibold))
          .foregroundStyle(.red.opacity(0.9))
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .allowsHitTesting(false)
  }

  // MARK: - Helpers

  private func chipKey(_ type: String, _ index: Int) -> String { "\(type)_\(index)" }

  private func outputAtPosition(_ point: CGPoint) -> Int? {
    for i in 0..<outputCount {
      if let src = dragSourceInput,
         MatrixNamesHelper.isRoutingBlocked(
           input: src, output: i, customFields: control.customFields, isLive: true) {
        continue
      }
      if let frame = chipFrames[chipKey("out", i)],
         frame.insetBy(dx: -10, dy: -10).contains(point) {
        return i
      }
    }
    return nil
  }

  private func performRoute(input: Int, output: Int) {
    print("[LiveMatrix] performRoute input=\(input) output=\(output)  bindingDeviceID=\(control.binding?.deviceID.uuidString ?? "nil")")

    // Blacklist check
    let blocked = MatrixNamesHelper.blockedInputs(forOutput: output, customFields: control.customFields, isLive: true)
    if blocked.contains(input) {
      runtimeStore.triggerErrorHaptic()
      blockedOutput = output
      withAnimation(.linear(duration: 0.4)) { blockedShakeCounter += 1 }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { blockedOutput = nil }
      return
    }

    guard let dev = device else {
      print("[LiveMatrix] ❌ device is nil — binding not matched in devices list")
      runtimeStore.triggerErrorHaptic()
      OperationLogStore.shared.append(controlTitle: control.title, commandName: "Route failed", payload: template, deviceName: "—", deviceHost: "—")
      OperationLogStore.shared.markLastResult(.failure("Device not bound – check binding in Editor"))
      return
    }

    print("[LiveMatrix] Device found: \(dev.name) → \(dev.host):\(dev.port)")
    runtimeStore.triggerHaptic(.medium)
    sendingRoute = "\(output)"

    let inputCmd = inputCmds[input]
    let outputCmd = outputCmds[output]
    let payload = template
      .replacingOccurrences(of: "{input}", with: inputCmd)
      .replacingOccurrences(of: "{output}", with: outputCmd)

    print("[LiveMatrix] Sending payload: \"\(payload)\"")
    OperationLogStore.shared.append(
      controlTitle: control.title,
      commandName: "\(inputNames[input]) → \(outputNames[output])",
      payload: payload, deviceName: dev.name, deviceHost: dev.host
    )

    let previousInput = routedInput(for: output)
    routeGenerationCounter += 1
    let generation = routeGenerationCounter
    routeGenerations[output] = generation
    runtimeStore.setRoutedInput(input, parentID: control.id, outputIndex: output)

    Task {
      do {
        try await transport.sendRaw(
          device: dev, payload: payload,
          lineEnding: lineEnding, timeoutMs: timeoutMs
        )
        await MainActor.run {
          guard routeGenerations[output] == generation else { return }
          sendingRoute = nil
          runtimeStore.triggerHaptic(.rigid)
          OperationLogStore.shared.markLastResult(.success)
        }
      } catch {
        await MainActor.run {
          guard routeGenerations[output] == generation else { return }
          sendingRoute = nil
          if let previousInput {
            runtimeStore.setRoutedInput(previousInput, parentID: control.id, outputIndex: output)
          }
          runtimeStore.triggerErrorHaptic()
          OperationLogStore.shared.markLastResult(.failure(error.localizedDescription))
        }
      }
    }
  }

  private func lmParseFontWeight(_ value: String) -> Font.Weight {
    switch value {
    case "regular": return .regular
    case "medium": return .medium
    case "bold": return .bold
    default: return .semibold
    }
  }
}

// MARK: - Flat Chip Views (independent input/output tiles)

struct MatrixChipTileView: View {
  let control: ControlItem
  let allControls: [ControlItem]
  let device: DeviceItem?
  let transport: TcpTransport
  @ObservedObject var runtimeStore: RuntimeControlStore
  let styles: StyleItem
  let theme: ThemeColors
  let canvasCellW: CGFloat
  @Binding var selectedInput: SelectedMatrixInput?
  @Binding var explodedDrag: ExplodedChipDrag?
  @EnvironmentObject private var streamHub: MJPEGStreamHub

  private var chipName: String { control.customFields["chipName"] ?? control.title }
  private var chipIndex: Int { Int(control.customFields["chipIndex"] ?? "") ?? 0 }
  private var chipCmd: String { control.customFields["chipCmd"] ?? "\(chipIndex)" }
  private var parentID: UUID? { UUID(uuidString: control.customFields["parentControlID"] ?? "") }
  private var parentIDString: String { control.customFields["parentControlID"] ?? "" }
  private var isInput: Bool { control.type == .matrixInput || control.type == .liveMatrixInput }
  private var isLive: Bool { control.type == .liveMatrixInput || control.type == .liveMatrixOutput }

  private var parent: ControlItem? {
    guard let pid = parentID else { return nil }
    return allControls.first(where: { $0.id == pid })
  }

  private var staticMatrixFields: [String: String] { parent?.customFields ?? [:] }

  private var staticInputAccent: Color {
    MatrixNamesHelper.parseColor(staticMatrixFields["matrixInputColor"] ?? "blue")
  }

  private var staticDragAccent: Color {
    MatrixNamesHelper.matrixDragColor(in: staticMatrixFields, fallback: staticInputAccent)
  }

  private var isInputSelected: Bool {
    guard isInput, let sel = selectedInput else { return false }
    return sel.parentID == (parentID ?? control.id) && sel.index == chipIndex
  }

  /// Whether an active drag from a sibling input is hovering over this output chip.
  private var isDragHovering: Bool {
    guard !isInput, let drag = explodedDrag, drag.parentID == parentIDString else { return false }
    let fx = CGFloat(control.placement.x) * canvasCellW
    let fy = CGFloat(control.placement.y) * canvasCellW
    let fw = CGFloat(control.placement.w) * canvasCellW
    let fh = CGFloat(control.placement.h) * canvasCellW
    return CGRect(x: fx, y: fy, width: fw, height: fh).contains(drag.position)
  }

  /// Whether this output chip should be hidden while a source is being dragged to route.
  private var isHiddenDuringExplodedDrag: Bool {
    guard !isInput, let drag = explodedDrag, drag.parentID == parentIDString, let p = parent else {
      return false
    }
    return MatrixNamesHelper.isRoutingBlocked(
      input: drag.inputIndex, output: chipIndex, customFields: p.customFields, isLive: isLive)
  }

  /// Whether the currently selected tap-input is blocked for this output chip.
  private var isSelectionBlocked: Bool {
    guard !isInput, let sel = selectedInput, sel.parentID == (parentID ?? control.id) else { return false }
    guard let p = parent else { return false }
    let blocked = MatrixNamesHelper.blockedInputs(forOutput: chipIndex, customFields: p.customFields, isLive: isLive)
    return blocked.contains(sel.index)
  }

  /// Live output: routed input index from shared store (matches LiveMatrix `outputChip`).
  @State private var sendingRoute: String? = nil
  @State private var routeGeneration: UInt64 = 0
  @State private var blockedFlash: Bool = false
  @State private var blockedShakeCounter: CGFloat = 0

  private var effectiveRoutedInputIndex: Int? {
    guard !isInput, let pid = parentID, let p = parent else { return nil }
    if let stored = runtimeStore.routedInput(parentID: pid, outputIndex: chipIndex) {
      return stored
    }
    if isLive {
      let inCount = parentInputCount(p: p)
      return chipIndex < inCount ? chipIndex : nil
    }
    return nil
  }

  var body: some View {
    GeometryReader { geo in
      chipBody(chipW: geo.size.width, chipH: geo.size.height)
    }
    .opacity(isHiddenDuringExplodedDrag ? 0 : 1)
    .allowsHitTesting(!isHiddenDuringExplodedDrag)
    .animation(.easeInOut(duration: 0.18), value: isHiddenDuringExplodedDrag)
    .contentShape(Rectangle())
    .overlay {
      if isDragHovering {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(isLive ? theme.activeBorder : staticDragAccent, lineWidth: 3)
          .animation(.easeInOut(duration: 0.12), value: isDragHovering)
      }
      // Pre-warn border when a tap-selected input is blocked for this output
      if isSelectionBlocked && !isDragHovering {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(Color.red.opacity(0.6), lineWidth: 2)
          .animation(.easeInOut(duration: 0.2), value: isSelectionBlocked)
        VStack {
          HStack {
            Spacer()
            Image(systemName: "lock.slash.fill")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(.red)
              .padding(4)
          }
          Spacer()
        }
      }
    }
    .modifier(ShakeEffect(animatableData: blockedShakeCounter))
    .onAppear { seedDefaultRouteIfNeeded() }
    .onTapGesture { handleTap() }
    .simultaneousGesture(
      DragGesture(minimumDistance: 8, coordinateSpace: .named("controlsGrid"))
        .onChanged { value in
          guard isInput else { return }
          explodedDrag = ExplodedChipDrag(
            parentID: parentIDString,
            inputIndex: chipIndex,
            inputCmd: chipCmd,
            chipName: chipName,
            isLive: isLive,
            position: value.location
          )
        }
        .onEnded { value in
          guard isInput else { return }
          routeIfDroppedOnOutput(at: value.location)
          explodedDrag = nil
        }
    )
  }

  private func triggerBlockedFeedback() {
    runtimeStore.triggerErrorHaptic()
    withAnimation(.linear(duration: 0.4)) { blockedShakeCounter += 1 }
  }

  /// Checks whether the drag endpoint landed on a sibling output chip; routes if so.
  private func routeIfDroppedOnOutput(at pos: CGPoint) {
    let outputTypes: Set<ControlType> = isLive ? [.liveMatrixOutput] : [.matrixOutput]
    for chip in allControls where outputTypes.contains(chip.type)
          && chip.customFields["parentControlID"] == parentIDString {
      let fx = CGFloat(chip.placement.x) * canvasCellW
      let fy = CGFloat(chip.placement.y) * canvasCellW
      let fw = CGFloat(chip.placement.w) * canvasCellW
      let fh = CGFloat(chip.placement.h) * canvasCellW
      if CGRect(x: fx, y: fy, width: fw, height: fh).contains(pos) {
        let outIdx = Int(chip.customFields["chipIndex"] ?? "") ?? 0
        if let p = parent,
           MatrixNamesHelper.isRoutingBlocked(
             input: chipIndex, output: outIdx, customFields: p.customFields, isLive: isLive) {
          continue
        }
        let outCmd = chip.customFields["chipCmd"] ?? "\(outIdx)"
        performRoute(inputCmd: chipCmd, outputCmd: outCmd, outputIndex: outIdx, inputIndex: chipIndex)
        return
      }
    }
  }

  // MARK: - Stream URL (same contract as `LiveMatrixTileView`)

  private func liveStreamURL(parent: ControlItem, ip: String, port: String, devID: String) -> URL? {
    LiveMatrixStreamURL.build(
      customFields: parent.customFields,
      ip: ip,
      port: port,
      devID: devID
    )
  }

  private func parentInputCount(p: ControlItem) -> Int {
    if isLive {
      return max(1, Int(p.customFields["liveMatrixInputCount"] ?? "") ?? 4)
    }
    return max(1, Int(p.customFields["matrixInputCount"] ?? "") ?? 4)
  }

  private func parentStringArray(p: ControlItem, key: String, count: Int, fallback: String) -> [String] {
    guard let json = p.customFields[key], let data = json.data(using: .utf8),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else {
      return Array(repeating: fallback, count: count)
    }
    var result = arr
    while result.count < count { result.append(fallback) }
    return Array(result.prefix(count))
  }

  private func parentInputName(p: ControlItem, index: Int) -> String {
    let c = parentInputCount(p: p)
    let prefix = isLive
      ? (p.customFields["liveMatrixInputPrefix"] ?? "Tx")
      : (p.customFields["matrixInputPrefix"] ?? "IN")
    let key = isLive ? "liveMatrixInputNames" : "matrixInputNames"
    let list = MatrixNamesHelper.parseNames(p.customFields[key], count: c, prefix: prefix)
    guard index >= 0, index < list.count else { return "" }
    return list[index]
  }

  @ViewBuilder
  private func chipBody(chipW: CGFloat, chipH: CGFloat) -> some View {
    if isLive, let p = parent, p.type == .liveMatrix {
      liveMatrixChipBody(parent: p, designW: chipW, designH: chipH)
    } else {
      staticMatrixChipBody(chipW: chipW, chipH: chipH)
    }
  }

  @ViewBuilder
  private func liveMatrixChipBody(parent: ControlItem, designW: CGFloat, designH: CGFloat) -> some View {
    let fontSize = CGFloat(Double(parent.customFields["liveMatrixFontSize"] ?? "") ?? 12)
    let fontW = matrixChipLiveFontWeight(parent.customFields["liveMatrixFontWeight"] ?? "semibold")
    let textSz = max(min(fontSize, designW * 0.12), 8)
    let srcTextSz = max(min(fontSize * 0.75, designW * 0.10), 7)

    let inCount = parentInputCount(p: parent)
    let inputURL: URL? = {
      if isInput {
        let idx = chipIndex
        let ips = parentStringArray(p: parent, key: "liveMatrixInputStreamIPs", count: inCount, fallback: "")
        let ports = parentStringArray(p: parent, key: "liveMatrixInputStreamPorts", count: inCount, fallback: "8080")
        let devs = parentStringArray(p: parent, key: "liveMatrixInputStreamDevIDs", count: inCount, fallback: "")
        guard idx >= 0, idx < inCount else { return nil }
        return liveStreamURL(parent: parent, ip: ips[idx], port: ports[idx], devID: devs[idx])
      }
      guard let r = effectiveRoutedInputIndex, r >= 0, r < inCount else { return nil }
      let ips = parentStringArray(p: parent, key: "liveMatrixInputStreamIPs", count: inCount, fallback: "")
      let ports = parentStringArray(p: parent, key: "liveMatrixInputStreamPorts", count: inCount, fallback: "8080")
      let devs = parentStringArray(p: parent, key: "liveMatrixInputStreamDevIDs", count: inCount, fallback: "")
      return liveStreamURL(parent: parent, ip: ips[r], port: ports[r], devID: devs[r])
    }()

    let isBusy = sendingRoute == "\(chipIndex)"
    let hasRoute = !isInput && effectiveRoutedInputIndex != nil
    let chipBgColor: Color = {
      if isBusy { return theme.idleButtonBg.opacity(0.8) }
      if !isInput, hasRoute { return theme.activeButtonBg.opacity(0.55) }
      if isInput { return isInputSelected ? theme.activeButtonBg : theme.idleButtonBg }
      return theme.idleButtonBg
    }()
    let borderColor: Color = {
      if isBusy { return .orange.opacity(0.6) }
      if isInput { return isInputSelected ? theme.activeBorder : theme.idleBorder }
      if hasRoute { return theme.activeBorder.opacity(0.6) }
      return theme.idleBorder
    }()
    let borderW: CGFloat = (isInput && isInputSelected) || isBusy || hasRoute ? 2.0 : 1.5

    GeometryReader { geo in
      let scX = geo.size.width / designW
      let scY = geo.size.height / designH
      let sc = min(scX, scY, 1.0)
      let cw = designW * sc
      let ch = designH * sc

      Group {
        if isInput {
          VStack(spacing: 3) {
            ZStack(alignment: .bottomLeading) {
              ZStack {
                SharedMJPEGView(url: inputURL, cornerRadius: 8)
                  .frame(width: cw, height: ch)
              }
              Text(chipName)
                .font(.system(size: textSz, weight: fontW))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(chipBgColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: styles.shadowBlur, x: 0, y: styles.shadowY)
            .overlay {
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: borderW)
            }
          }
        } else {
          VStack(spacing: 3) {
            ZStack(alignment: .bottom) {
              SharedMJPEGView(url: inputURL, cornerRadius: 8)
                .frame(width: cw, height: ch)

              HStack(spacing: 4) {
                Text(chipName)
                  .font(.system(size: textSz, weight: fontW))
                  .foregroundStyle(.white)
                  .lineLimit(1)
                  .minimumScaleFactor(0.5)
                if let r = effectiveRoutedInputIndex {
                  Text("← \(parentInputName(p: parent, index: r))")
                    .font(.system(size: srcTextSz, weight: .medium))
                    .foregroundStyle(theme.activeBorder)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
              }
              .animation(.spring(response: 0.3, dampingFraction: 0.7), value: effectiveRoutedInputIndex)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
              .padding(4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(chipBgColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: styles.shadowBlur, x: 0, y: styles.shadowY)
            .overlay {
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: borderW)
            }
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder
  private func staticMatrixChipBody(chipW: CGFloat, chipH: CGFloat) -> some View {
    let icon = isInput ? "video.fill" : "display"
    let textSz = max(min(14, chipW * 0.12), 8)
    let srcTextSz = max(min(10.0, chipW * 0.10), 7)
    let parentTitle = control.customFields["parentTitle"] ?? ""
    let parentSz = max(min(9.0, chipW * 0.09), 7)
    let colorKey = isInput ? "matrixInputColor" : "matrixOutputColor"
    let colorFallback = isInput ? "blue" : "green"
    let accent = MatrixNamesHelper.parseColor(parent?.customFields[colorKey] ?? colorFallback)
    let labelColor = MatrixNamesHelper.parseColor(parent?.customFields["matrixTextColor"] ?? "white")
    let fields = parent?.customFields ?? [:]
    let dragColor = MatrixNamesHelper.matrixDragColor(in: fields, fallback: staticInputAccent)
    let routedInput = effectiveRoutedInputIndex
    let hasRoute = !isInput && routedInput != nil
    let isBusy = sendingRoute == "\(chipIndex)"
    let isAwaitingOutput = !isInput && selectedInput?.parentID == parentID

    let chipFill: Color = {
      if isInput {
        return isInputSelected ? accent.opacity(0.60) : accent.opacity(0.30)
      }
      if isBusy { return accent.opacity(0.50) }
      if isDragHovering { return dragColor.opacity(0.65) }
      if isAwaitingOutput && !isSelectionBlocked { return accent.opacity(0.38) }
      if hasRoute { return accent.opacity(0.45) }
      return accent.opacity(0.28)
    }()
    let borderColor: Color = {
      if isInput {
        return isInputSelected
          ? MatrixNamesHelper.matrixBorderColor(in: fields, accent: accent, emphasized: true)
          : MatrixNamesHelper.matrixBorderColor(in: fields, accent: accent, emphasized: false)
      }
      if isBusy { return .orange.opacity(0.6) }
      if isDragHovering { return dragColor }
      if isSelectionBlocked { return .red.opacity(0.6) }
      if isAwaitingOutput {
        return MatrixNamesHelper.matrixBorderColor(in: fields, accent: accent, emphasized: true)
      }
      if hasRoute {
        return MatrixNamesHelper.matrixBorderColor(in: fields, accent: accent, emphasized: true)
      }
      return MatrixNamesHelper.matrixBorderColor(in: fields, accent: accent, emphasized: false)
    }()
    let borderW: CGFloat = {
      if isInput { return isInputSelected ? 2.5 : 1.5 }
      return (isBusy || isDragHovering || hasRoute || isSelectionBlocked || isAwaitingOutput) ? 2.0 : 1.5
    }()

    GeometryReader { geo in
      let scX = geo.size.width / chipW
      let scY = geo.size.height / chipH
      let sc = min(scX, scY, 1.0)
      let cw = chipW * sc
      let ch = chipH * sc

      ZStack(alignment: .bottomLeading) {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(chipFill)
        Image(systemName: icon)
          .font(.system(size: max(min(cw * 0.18, ch * 0.25), 8), weight: .medium))
          .foregroundStyle(labelColor.opacity(isInput || hasRoute ? 0.65 : 0.35))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        if isInput {
          Text(chipName)
            .font(.system(size: textSz, weight: .semibold))
            .foregroundStyle(labelColor)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .padding(4)
        } else {
          HStack(spacing: 4) {
            Text(chipName)
              .font(.system(size: textSz, weight: .semibold))
              .foregroundStyle(labelColor)
              .lineLimit(1)
              .minimumScaleFactor(0.5)
            if let r = routedInput, let p = parent {
              Text("← \(parentInputName(p: p, index: r))")
                .font(.system(size: srcTextSz, weight: .medium))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
          }
          .animation(.spring(response: 0.3, dampingFraction: 0.7), value: routedInput)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
          .padding(4)
        }
      }
      .frame(width: cw, height: ch)
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(alignment: .topLeading) {
        if !parentTitle.isEmpty {
          Text(parentTitle)
            .font(.system(size: parentSz, weight: .medium))
            .foregroundStyle(.white.opacity(0.75))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .padding(4)
        }
      }
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(borderColor, lineWidth: borderW)
      }
      .shadow(color: .black.opacity(0.35), radius: styles.shadowBlur, x: 0, y: styles.shadowY)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func matrixChipLiveFontWeight(_ value: String) -> Font.Weight {
    switch value {
    case "regular": return .regular
    case "medium": return .medium
    case "bold": return .bold
    default: return .semibold
    }
  }

  private func seedDefaultRouteIfNeeded() {
    guard !isInput, let pid = parentID, let p = parent else { return }
    guard runtimeStore.routedInput(parentID: pid, outputIndex: chipIndex) == nil else { return }
    let inCount = parentInputCount(p: p)
    guard chipIndex < inCount else { return }
    runtimeStore.setRoutedInput(chipIndex, parentID: pid, outputIndex: chipIndex)
  }

  private func handleTap() {
    let pid = parentID ?? control.id
    if isInput {
      if selectedInput?.parentID == pid && selectedInput?.index == chipIndex {
        selectedInput = nil
      } else {
        selectedInput = SelectedMatrixInput(parentID: pid, index: chipIndex, cmd: chipCmd)
      }
      runtimeStore.triggerHaptic(.light)
    } else {
      guard let sel = selectedInput, sel.parentID == pid else {
        runtimeStore.triggerHaptic(.light)
        return
      }
      // Blacklist check before routing
      if let p = parent {
        let blocked = MatrixNamesHelper.blockedInputs(forOutput: chipIndex, customFields: p.customFields, isLive: isLive)
        if blocked.contains(sel.index) {
          triggerBlockedFeedback()
          return
        }
      }
      performRoute(
        inputCmd: sel.cmd, outputCmd: chipCmd, outputIndex: chipIndex, inputIndex: sel.index
      )
    }
  }

  private func performRoute(
    inputCmd: String, outputCmd: String, outputIndex: Int, inputIndex: Int? = nil
  ) {
    guard let p = parent else {
      runtimeStore.triggerErrorHaptic()
      return
    }
    // Final blacklist guard (defensive)
    if let idx = inputIndex {
      let blocked = MatrixNamesHelper.blockedInputs(forOutput: outputIndex, customFields: p.customFields, isLive: isLive)
      if blocked.contains(idx) {
        triggerBlockedFeedback()
        return
      }
    }
    let pfx = isLive ? "liveMatrix" : "matrix"
    let defaultTemplate = isLive ? "matrix aset :av {input} {output}" : "{output} VS {input}"
    let parentTemplate = p.customFields["\(pfx)CommandTemplate"] ?? defaultTemplate
    let chipOverride = control.customFields["chipCommandTemplate"]
    let template = (chipOverride?.isEmpty == false ? chipOverride! : parentTemplate)
    let lineEnding = LineEnding(rawValue: p.customFields["\(pfx)LineEnding"] ?? "crlf") ?? .crlf
    let timeoutMs = Int(p.customFields["\(pfx)TimeoutMs"] ?? "") ?? 1500

    guard let dev = device else {
      runtimeStore.triggerErrorHaptic()
      return
    }

    let payload = template
      .replacingOccurrences(of: "{input}", with: inputCmd)
      .replacingOccurrences(of: "{output}", with: outputCmd)

    runtimeStore.triggerHaptic(.medium)
    sendingRoute = "\(outputIndex)"

    OperationLogStore.shared.append(
      controlTitle: p.title,
      commandName: "\(inputCmd) → \(outputCmd)",
      payload: payload, deviceName: dev.name, deviceHost: dev.host
    )

    let pid = parentID ?? p.id
    let previousInput = runtimeStore.routedInput(parentID: pid, outputIndex: outputIndex)
    routeGeneration += 1
    let generation = routeGeneration
    if let idx = inputIndex {
      runtimeStore.setRoutedInput(idx, parentID: pid, outputIndex: outputIndex)
    }

    Task {
      do {
        try await transport.sendRaw(
          device: dev, payload: payload,
          lineEnding: lineEnding, timeoutMs: timeoutMs
        )
        await MainActor.run {
          guard routeGeneration == generation else { return }
          sendingRoute = nil
          runtimeStore.triggerHaptic(.rigid)
          OperationLogStore.shared.markLastResult(.success)
        }
      } catch {
        await MainActor.run {
          guard routeGeneration == generation else { return }
          sendingRoute = nil
          if let previousInput {
            runtimeStore.setRoutedInput(previousInput, parentID: pid, outputIndex: outputIndex)
          } else {
            runtimeStore.clearRoutedInput(parentID: pid, outputIndex: outputIndex)
          }
          runtimeStore.triggerErrorHaptic()
          OperationLogStore.shared.markLastResult(.failure(error.localizedDescription))
        }
      }
    }
  }
}

struct SelectedMatrixInput: Equatable {
  let parentID: UUID
  let index: Int
  let cmd: String
}

/// Drag-to-route state shared across exploded chip tiles on the canvas.
struct ExplodedChipDrag: Equatable {
  let parentID: String
  let inputIndex: Int
  let inputCmd: String
  let chipName: String
  let isLive: Bool
  var position: CGPoint
}

/// Horizontal shake animation used when a blocked route is attempted.
struct ShakeEffect: GeometryEffect {
  var amount: CGFloat = 5
  var shakesPerUnit: Int = 3
  var animatableData: CGFloat
  func effectValue(size: CGSize) -> ProjectionTransform {
    let dx = amount * sin(animatableData * .pi * CGFloat(shakesPerUnit))
    return ProjectionTransform(CGAffineTransform(translationX: dx, y: 0))
  }
}

// MARK: - Volume Level Tile View (Notched Slider)

private struct VolumeLevelTileView: View {
  let control: ControlItem
  let device: DeviceItem?
  let commands: [CommandItem]
  let transport: TcpTransport
  let runtimeStore: RuntimeControlStore
  let styles: StyleItem
  let theme: ThemeColors
  let isEditMode: Bool

  @State private var currentLevel: Int = -1
  @State private var sendingLevel: Int? = nil
  @State private var didApplyDefault = false
  @State private var isDragging = false
  @State private var isPressRevealing = false

  private var levelCount: Int { max(2, Int(control.customFields["volumeLevelCount"] ?? "") ?? 8) }
  private var activeColorName: String { control.customFields["volumeActiveColor"] ?? "green" }
  private var inactiveColorName: String { control.customFields["volumeInactiveColor"] ?? "gray" }
  /// "top" (default) / "bottom" / "hidden"
  private var titlePosition: String { control.customFields["volumeTitlePosition"] ?? "top" }
  private var isHiddenMode: Bool { control.customFields["volumeLevelVisibility"] == "hidden" }

  private var defaultLevel: Int {
    let pos = control.customFields["volumeDefaultPosition"] ?? "center"
    switch pos {
    case "top": return levelCount - 1
    case "bottom": return 0
    default: return (levelCount - 1) / 2
    }
  }

  private var levelCommandIDs: [UUID?] {
    guard let json = control.customFields["volumeLevelCommandIDs"],
          let data = json.data(using: .utf8),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
    else { return Array(repeating: nil, count: levelCount) }
    var result = arr.map { UUID(uuidString: $0) }
    while result.count < levelCount { result.append(nil) }
    return Array(result.prefix(levelCount))
  }

  private var levelLabels: [String] {
    if let json = control.customFields["volumeLevelLabels"],
       let data = json.data(using: .utf8),
       let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
      var result = arr
      while result.count < levelCount { result.append("") }
      return Array(result.prefix(levelCount))
    }
    return (0..<levelCount).map { "\($0)" }
  }

  private let trackW: CGFloat = 4
  private let thumbH: CGFloat = 12
  private let thumbW: CGFloat = 30
  private let notchW: CGFloat = 14

  var body: some View {
    let showTitle = titlePosition != "hidden" && !control.title.isEmpty
    let titleH: CGFloat = showTitle ? 18 : 0

    let hiddenOpacity: Double = isHiddenMode && !isEditMode ? (isPressRevealing ? 1 : 0) : 1

    GeometryReader { geo in
      let pad: CGFloat = 12
      let sliderH = geo.size.height - titleH - pad * 2
      let sliderCenterX = geo.size.width / 2
      let labels = levelLabels

      ZStack {
        // Visual layer — hidden when isHiddenMode && !isPressRevealing
        VStack(spacing: 0) {
          if showTitle && titlePosition == "top" { titleView.frame(height: titleH) }

          ZStack {
            // Track line
            RoundedRectangle(cornerRadius: trackW / 2)
              .fill(lvlParseColor(inactiveColorName).opacity(0.25))
              .frame(width: trackW, height: sliderH)
              .position(x: sliderCenterX - pad, y: sliderH / 2)

            // Notch marks
            ForEach(0..<levelCount, id: \.self) { i in
              let y = yForLevel(i, height: sliderH)
              Rectangle()
                .fill(theme.textColor.opacity(0.3))
                .frame(width: notchW, height: 1)
                .position(x: sliderCenterX - pad, y: y)
                .opacity((isDragging || isPressRevealing) ? 1 : 0)

              if i < labels.count, !labels[i].isEmpty {
                Text(labels[i])
                  .font(.system(size: 9, weight: .medium, design: .monospaced))
                  .foregroundStyle(theme.textColor.opacity(i == currentLevel ? 0.9 : 0.4))
                  .lineLimit(1)
                  .minimumScaleFactor(0.5)
                  .fixedSize(horizontal: false, vertical: true)
                  .frame(width: geo.size.width / 2 - 6, alignment: .leading)
                  .position(
                    x: sliderCenterX - pad + thumbW / 2 + 6 + (geo.size.width / 2 - 6) / 2,
                    y: y
                  )
                  .opacity((isDragging || isPressRevealing) ? 1 : 0)
              }
            }

            // Thumb
            if currentLevel >= 0 {
              let y = yForLevel(currentLevel, height: sliderH)
              let isBusy = sendingLevel != nil
              RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(isBusy ? Color.orange : lvlParseColor(activeColorName))
                .frame(width: thumbW, height: thumbH)
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                .position(x: sliderCenterX - pad, y: y)
                .animation(.easeOut(duration: 0.15), value: currentLevel)
            }
          }
          .frame(height: sliderH)

          if showTitle && titlePosition == "bottom" { titleView.frame(height: titleH) }
        }
        .padding(pad)
        .opacity(hiddenOpacity)
        .allowsHitTesting(false)

        // Gesture layer — always interactive, never affected by opacity
        Color.clear
          .contentShape(Rectangle())
          .padding(pad)
          .gesture(
            LongPressGesture(minimumDuration: isHiddenMode && !isEditMode ? 0.5 : 0.01)
              .sequenced(before: DragGesture(minimumDistance: 0))
              .onChanged { value in
                guard !isEditMode else { return }
                switch value {
                case .second(true, let drag):
                  if isHiddenMode && !isPressRevealing {
                    withAnimation(.easeOut(duration: 0.15)) { isPressRevealing = true }
                  }
                  guard let drag = drag else { return }
                  if !isDragging { withAnimation(.easeOut(duration: 0.15)) { isDragging = true } }
                  let level = levelFromY(drag.location.y, sliderHeight: sliderH)
                  if level != currentLevel && sendingLevel == nil {
                    performLevelChange(level: level)
                  }
                default:
                  break
                }
              }
              .onEnded { _ in
                withAnimation(.easeOut(duration: 0.25)) {
                  isDragging = false
                  if isHiddenMode { isPressRevealing = false }
                }
              }
          )
      }
    }
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(theme.idleButtonBg)
        .opacity(hiddenOpacity)
    )
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .shadow(color: .black.opacity(0.3 * hiddenOpacity), radius: styles.shadowBlur, x: 0, y: styles.shadowY)
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(theme.idleBorder, lineWidth: 1)
        .opacity(hiddenOpacity)
    }
    .contentShape(Rectangle())
    .onAppear {
      if !didApplyDefault {
        currentLevel = max(0, min(defaultLevel, levelCount - 1))
        didApplyDefault = true
      }
    }
  }

  private var titleView: some View {
    Text(control.title)
      .font(.system(size: 10, weight: .medium))
      .foregroundStyle(theme.textColor.opacity(0.55))
      .lineLimit(1)
      .minimumScaleFactor(0.5)
  }

  private func yForLevel(_ level: Int, height: CGFloat) -> CGFloat {
    let topPad: CGFloat = thumbH / 2
    let usable = height - thumbH
    let fraction = CGFloat(level) / CGFloat(max(levelCount - 1, 1))
    return topPad + usable * (1.0 - fraction)
  }

  private func levelFromY(_ y: CGFloat, sliderHeight: CGFloat) -> Int {
    let topPad: CGFloat = thumbH / 2
    let usable = sliderHeight - thumbH
    let fraction = 1.0 - ((y - topPad) / usable)
    let level = Int(round(fraction * CGFloat(levelCount - 1)))
    return max(0, min(levelCount - 1, level))
  }

  private func performLevelChange(level: Int) {
    guard sendingLevel == nil else { return }

    runtimeStore.triggerHaptic(.light)
    currentLevel = level

    let cmdIDs = levelCommandIDs
    guard let dev = device,
          level < cmdIDs.count,
          let cmdID = cmdIDs[level],
          let command = commands.first(where: { $0.id == cmdID })
    else { return }

    sendingLevel = level

    OperationLogStore.shared.append(
      controlTitle: control.title,
      commandName: "Level \(level): \(levelLabels[level])",
      payload: command.payload, deviceName: dev.name, deviceHost: dev.host
    )

    Task {
      do {
        try await transport.send(device: dev, command: command)
        await MainActor.run {
          sendingLevel = nil
          runtimeStore.triggerHaptic(.rigid)
          OperationLogStore.shared.markLastResult(.success)
        }
      } catch {
        await MainActor.run {
          sendingLevel = nil
          runtimeStore.triggerErrorHaptic()
          OperationLogStore.shared.markLastResult(.failure(error.localizedDescription))
        }
      }
    }
  }

  private func lvlParseColor(_ value: String) -> Color {
    switch value {
    case "black": return .black
    case "gray": return .gray
    case "blue": return .blue
    case "green": return .green
    case "orange": return .orange
    case "red": return .red
    case "cyan": return .cyan
    case "yellow": return .yellow
    case "purple": return .purple
    case "pink": return .pink
    case "mint": return .mint
    case "teal": return .teal
    default: return .white
    }
  }
}

private struct ChipFrameKey: PreferenceKey {
  static var defaultValue: [String: CGRect] = [:]
  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { $1 })
  }
}
