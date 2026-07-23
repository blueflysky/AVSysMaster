import Combine
import PhotosUI
import SwiftUI

// MARK: - Editor Page

struct EditorPageView: View {
  @EnvironmentObject private var modelStore: UnifiedModelStore
  @Environment(\.dismiss) private var dismiss

  var isFullscreen: Bool = false
  var onRequestFullscreen: (() -> Void)?

  @State private var selectedControlID: UUID?
  @State private var editingControl: ControlItem?
  @State private var logoPickerItem: PhotosPickerItem?
  @State private var bgPickerItem: PhotosPickerItem?
  @State private var alertMessage: AlertMessage?
  @State private var panelExpanded = true
  /// Editor: sub-divisions per cell for BOTH visual grid lines AND drag snap.
  /// 1 = snap to whole cells; 2 = half-cell; 4 = quarter-cell.
  @State private var editorGridSubdivisions: Int = 2
  /// Parent matrix IDs (uuidString) whose chip children are currently expanded in the Elements list.
  @State private var expandedMatrixParents: Set<String> = []
  private let panelWidth: CGFloat = 280

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .trailing) {
        gridCanvas(canvasSize: geo.size)

        if panelExpanded {
          sidePanel(height: geo.size.height)
            .frame(width: panelWidth)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 12, x: -2, y: 0)
            .padding(.vertical, 8)
            .padding(.trailing, 8)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }

        VStack {
          HStack {
            if isFullscreen {
              Button { dismiss() } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                  .font(.body.weight(.semibold))
                  .frame(width: 36, height: 36)
                  .background(.ultraThinMaterial, in: Circle())
                  .shadow(color: .black.opacity(0.15), radius: 4)
              }
              .buttonStyle(.plain)
              .padding(.leading, 12)
              .padding(.top, 8)
            }

            Spacer()

            Button { confirmAndPublish() } label: {
              Image(systemName: "paperplane.fill")
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(.green.opacity(0.15), in: Circle())
                .foregroundStyle(.green)
                .shadow(color: .black.opacity(0.15), radius: 4)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)

            if !isFullscreen, let onRequestFullscreen {
              Button { onRequestFullscreen() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                  .font(.body.weight(.semibold))
                  .frame(width: 36, height: 36)
                  .background(.ultraThinMaterial, in: Circle())
                  .shadow(color: .black.opacity(0.15), radius: 4)
              }
              .buttonStyle(.plain)
              .padding(.trailing, 6)
            }

            Button {
              withAnimation(.easeInOut(duration: 0.22)) { panelExpanded.toggle() }
            } label: {
              Image(systemName: panelExpanded ? "xmark" : "sidebar.right")
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 4)
            }
            .buttonStyle(.plain)
            .padding(.trailing, panelExpanded ? panelWidth + 16 : 12)
            .padding(.top, 8)
          }
          Spacer()
        }
      }
      
    }
    .sheet(item: $editingControl) { ctrl in
      ControlPropertySheet(
        control: ctrl,
        onCommit: { updatedControl, updatedCommand in
          applyControlUpdate(updatedControl)
          if let cmd = updatedCommand {
            applyCommandUpdate(cmd)
          }
        },
        onSelectOther: { id in
          if let next = modelStore.draft.controls.first(where: { $0.id == id }) {
            editingControl = next
          }
        }
      )
      .environmentObject(modelStore)
    }
    .alert(item: $alertMessage) { item in
      Alert(title: Text(item.message))
    }
    .task(id: logoPickerItem) {
      guard let item = logoPickerItem else { return }
      if let data = try? await item.loadTransferable(type: Data.self),
        let path = try? saveImage(data: data, prefix: "logo")
      {
        modelStore.draft.styles.logoPath = path
      }
    }
    .task(id: bgPickerItem) {
      guard let item = bgPickerItem else { return }
      if let data = try? await item.loadTransferable(type: Data.self),
        let path = try? saveImage(data: data, prefix: "bg")
      {
        modelStore.draft.styles.backgroundPath = path
      }
    }
  }

  // MARK: - Grid Canvas

  private func gridCanvas(canvasSize: CGSize) -> some View {
    let runtimeSize = modelStore.runtimeCanvasSize
    let layout = modelStore.draft.layouts.first ?? .defaultLayout
    let columns = max(1, layout.columns)
    let cellW = runtimeSize.width / CGFloat(columns)
    let cellH = cellW
    let rows = max(1, Int(runtimeSize.height / cellH) + 1)

    let scaleX = canvasSize.width / runtimeSize.width
    let scaleY = canvasSize.height / runtimeSize.height
    let scale = min(scaleX, scaleY)
    let visibleControls = modelStore.draft.controls.filter { !$0.isExplodedMatrixParentHiddenFromCanvas }

    return ZStack(alignment: .topLeading) {
      Color(uiColor: .secondarySystemBackground)

      Rectangle()
        .stroke(Color.blue.opacity(0.25), style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
        .frame(width: runtimeSize.width, height: runtimeSize.height)

      GridLinesView(columns: columns, cellW: cellW, cellH: cellH, subdivisions: editorGridSubdivisions)

      ForEach(visibleControls) { control in
        DraggableTile(
          control: control,
          cellW: cellW,
          cellH: cellH,
          columns: columns,
          rows: rows,
          snapSubdivisions: editorGridSubdivisions,
          isSelected: selectedControlID == control.id,
          styles: modelStore.draft.styles,
          onSnap: { newX, newY in
            snapControl(control.id, toX: newX, toY: newY)
          },
          onResize: { newW, newH in
            resizeControl(control.id, toW: newW, toH: newH)
          },
          onTap: {
            selectedControlID = control.id
            editingControl = control
          },
          onDelete: {
            deleteControl(control)
          }
        )
      }

      if let logoImg = VisualTheme.logoImage(path: modelStore.draft.styles.logoPath) {
        DraggableLogo(
          image: logoImg,
          logoW: $modelStore.draft.styles.logoWidth,
          logoH: $modelStore.draft.styles.logoHeight,
          logoX: $modelStore.draft.styles.logoX,
          logoY: $modelStore.draft.styles.logoY,
          canvasWidth: runtimeSize.width,
          canvasHeight: runtimeSize.height
        )
      }

      if visibleControls.isEmpty && modelStore.draft.styles.logoPath == nil {
        VStack(spacing: 14) {
          Image(systemName: "square.grid.3x3.fill")
            .font(.system(size: 52))
            .foregroundStyle(.quaternary)
          Text("No Controls")
            .font(.title3.weight(.medium))
            .foregroundStyle(.secondary)
          Text("Tap the panel button to add controls")
            .font(.subheadline)
            .foregroundStyle(.tertiary)
        }
        .frame(width: runtimeSize.width, height: runtimeSize.height)
      }
    }
    .frame(width: runtimeSize.width, height: runtimeSize.height)
    .scaleEffect(scale, anchor: .topLeading)
    .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
    .clipped()
    .contentShape(Rectangle())
    .onTapGesture {
      selectedControlID = nil
    }
  }


  // MARK: - Side Panel

  private func sidePanel(height: CGFloat) -> some View {
    VStack(spacing: 0) {
      HStack {
        Text("Inspector")
          .font(.headline)
        Spacer()
        Button {
          withAnimation(.easeInOut(duration: 0.22)) { panelExpanded = false }
        } label: {
          Image(systemName: "xmark")
            .font(.caption.weight(.semibold))
            .frame(width: 28, height: 28)
            .background(.quaternary, in: Circle())
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)

      expandedPanel
    }
  }

  private var expandedPanel: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        panelSection("ADD CONTROLS") { addControlButtons }
        panelDivider
        panelSection("ELEMENTS") { elementsList }
        panelDivider
        panelSection("IMAGES") { imagePickerButtons }
        panelDivider
        panelSection("LAYOUT") { layoutSliders }
        panelDivider
        panelSection("EFFECTS") { effectSliders }
        panelDivider
        panelSection("PUBLISH") { confirmButtons }
        Spacer(minLength: 24)
      }
    }
    .scrollIndicators(.hidden)
  }

  // MARK: Panel Helpers

  private var panelDivider: some View {
    Divider().padding(.horizontal, 12).padding(.vertical, 4)
  }

  @ViewBuilder
  private func panelSection<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.caption2)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 12)

      VStack(spacing: 6) {
        content()
      }
      .padding(.horizontal, 12)
      .padding(.bottom, 4)
    }
  }

  // MARK: - Add Controls Section

  private var addControlButtons: some View {
    ForEach([ControlType.button, .slider, .toggle, .label, .icon, .border, .matrix, .liveMatrix, .volumeLevel], id: \.self) { type in
      Button { appendControl(type: type) } label: {
        HStack {
          Image(systemName: typeIcon(type))
            .frame(width: 22)
          Text(typeLabel(type))
          Spacer()
          Image(systemName: "plus")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
      }
      .buttonStyle(.plain)
    }
  }

  // MARK: - Elements List

  /// Controls shown at the top level of the Elements list.
  /// Chips whose parentControlID refers to an existing matrix / liveMatrix parent in `draft.controls`
  /// are hidden here and instead displayed under that parent as a collapsible sub-menu.
  private var topLevelElementControls: [ControlItem] {
    let parentIDs = Set(
      modelStore.draft.controls
        .filter { $0.type == .matrix || $0.type == .liveMatrix }
        .map { $0.id.uuidString }
    )
    return modelStore.draft.controls.filter { c in
      switch c.type {
      case .matrixInput, .matrixOutput, .liveMatrixInput, .liveMatrixOutput:
        let pid = c.customFields["parentControlID"] ?? ""
        return !parentIDs.contains(pid)
      default:
        return true
      }
    }
  }

  private func matrixChildChips(of parent: ControlItem) -> [ControlItem] {
    let pid = parent.id.uuidString
    let isLive = parent.type == .liveMatrix
    let chipTypes: Set<ControlType> = isLive
      ? [.liveMatrixInput, .liveMatrixOutput]
      : [.matrixInput, .matrixOutput]
    return modelStore.draft.controls.filter { c in
      chipTypes.contains(c.type) && c.customFields["parentControlID"] == pid
    }
    .sorted { a, b in
      let aIsInput = a.type == .matrixInput || a.type == .liveMatrixInput
      let bIsInput = b.type == .matrixInput || b.type == .liveMatrixInput
      if aIsInput != bIsInput { return aIsInput && !bIsInput }
      let aIdx = Int(a.customFields["chipIndex"] ?? "") ?? 0
      let bIdx = Int(b.customFields["chipIndex"] ?? "") ?? 0
      return aIdx < bIdx
    }
  }

  private var elementsList: some View {
    Group {
      if modelStore.draft.controls.isEmpty {
        Text("No elements yet")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(.vertical, 8)
      } else {
        ForEach(topLevelElementControls) { control in
          if control.type == .matrix || control.type == .liveMatrix {
            matrixElementRow(control)
          } else {
            elementRow(control, indented: false)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func matrixElementRow(_ control: ControlItem) -> some View {
    let pid = control.id.uuidString
    let chips = matrixChildChips(of: control)
    let isExpanded = expandedMatrixParents.contains(pid)
    // Width of the dedicated expand column.
    // Keeping it equal to the old (leading-padding + chevron + spacing = 10+14+8 = 32pt)
    // so the main content icon aligns to the same horizontal position as before.
    let expandColW: CGFloat = 32

    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 0) {
        // ── Expand / collapse zone ─────────────────────────────────────────
        // Fully isolated from elementRow's onTapGesture. Touch anywhere in
        // this 32pt column to toggle expansion; no conflict with row selection.
        ZStack {
          if !chips.isEmpty {
            Image(systemName: "chevron.right")
              .font(.system(size: 9, weight: .semibold))
              .rotationEffect(.degrees(isExpanded ? 90 : 0))
              .foregroundStyle(.secondary)
              .animation(.easeInOut(duration: 0.18), value: isExpanded)
          }
        }
        .frame(width: expandColW)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
          guard !chips.isEmpty else { return }
          withAnimation(.easeInOut(duration: 0.18)) {
            if isExpanded { expandedMatrixParents.remove(pid) }
            else          { expandedMatrixParents.insert(pid) }
          }
        }

        // ── Main row content ───────────────────────────────────────────────
        // elementRow's own onTapGesture only handles selection / inspector.
        elementRow(control, indented: false)
      }

      // Child chip rows — indented to align under the main row's content area.
      if isExpanded && !chips.isEmpty {
        ForEach(chips) { chip in
          elementRow(chip, indented: true)
            .padding(.leading, expandColW)
        }
      }
    }
  }

  @ViewBuilder
  private func elementRow<Leading: View>(
    _ control: ControlItem,
    indented: Bool,
    @ViewBuilder leading: () -> Leading = { EmptyView() }
  ) -> some View {
    let isSelected = selectedControlID == control.id
    HStack(spacing: 8) {
      leading()

      Image(systemName: typeIcon(control.type))
        .font(.caption)
        .foregroundStyle(isSelected ? .white : .secondary)
        .frame(width: 20)

      VStack(alignment: .leading, spacing: 1) {
        Text(control.title)
          .font(.caption.weight(.medium))
          .foregroundStyle(isSelected ? .white : .primary)
          .lineLimit(1)
        Text(
          control.isExplodedMatrixParentHiddenFromCanvas
            ? "\(typeLabel(control.type)) · template"
            : typeLabel(control.type)
        )
          .font(.system(size: 10))
          .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.gray.opacity(0.5))
      }

      Spacer()

      Text(fmtPlacement(control.placement.x) + "," + fmtPlacement(control.placement.y))
        .font(.system(size: 9, design: .monospaced))
        .foregroundStyle(isSelected ? Color.white.opacity(0.6) : Color.gray.opacity(0.35))

      if control.type == .matrix || control.type == .liveMatrix {
        Button {
          explodeToChips(control)
        } label: {
          Image(systemName: "square.grid.3x3")
            .font(.system(size: 11))
            .foregroundStyle(
              (isSelected ? Color.white : Color.cyan)
                .opacity(control.isExplodedMatrixParentHiddenFromCanvas ? 0.35 : 0.7)
            )
        }
        .buttonStyle(.plain)
        .disabled(control.isExplodedMatrixParentHiddenFromCanvas)
      }

      // Duplicate button — hidden for chip rows (matrixInput/Output etc.)
      if !control.type.isMatrixChip {
        Button {
          duplicateControl(control)
        } label: {
          Image(systemName: "doc.on.doc")
            .font(.system(size: 11))
            .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary.opacity(0.7))
        }
        .buttonStyle(.plain)
      }

      Button {
        deleteControl(control)
      } label: {
        Image(systemName: "trash")
          .font(.system(size: 11))
          .foregroundStyle(isSelected ? .white.opacity(0.7) : .red.opacity(0.6))
      }
      .buttonStyle(.plain)
    }
    .padding(.leading, indented ? 22 : 10)
    .padding(.trailing, 10)
    .padding(.vertical, 7)
    .background(
      isSelected ? Color.blue : Color.clear,
      in: RoundedRectangle(cornerRadius: 7)
    )
    .background(
      isSelected ? Color.clear : Color.white.opacity(0.03),
      in: RoundedRectangle(cornerRadius: 7)
    )
    .contentShape(RoundedRectangle(cornerRadius: 7))
    .onTapGesture {
      selectedControlID = control.id
      editingControl = control
    }
  }

  // MARK: - Images Section

  private var imagePickerButtons: some View {
    let hasLogo = modelStore.draft.styles.logoPath != nil
    let hasBg = modelStore.draft.styles.backgroundPath != nil

    return Group {
      PhotosPicker(selection: $logoPickerItem, matching: .images) {
        HStack {
          Image(systemName: "photo.badge.plus").frame(width: 22)
          Text("Set Logo")
          Spacer()
          if hasLogo {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.green).font(.caption)
          }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
      }
      .buttonStyle(.plain)

      PhotosPicker(selection: $bgPickerItem, matching: .images) {
        HStack {
          Image(systemName: "rectangle.fill.badge.plus").frame(width: 22)
          Text("Set Background")
          Spacer()
          if hasBg {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.green).font(.caption)
          }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
      }
      .buttonStyle(.plain)

      if modelStore.draft.styles.backgroundPath != nil {
        Button(role: .destructive) {
          modelStore.draft.styles.backgroundPath = nil
        } label: {
          HStack {
            Image(systemName: "trash").frame(width: 22)
            Text("Clear Background")
            Spacer()
          }
          .padding(.horizontal, 12).padding(.vertical, 9)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).foregroundStyle(.red)
      }

      if modelStore.draft.styles.logoPath != nil {
        Button(role: .destructive) {
          modelStore.draft.styles.logoPath = nil
        } label: {
          HStack {
            Image(systemName: "trash").frame(width: 22)
            Text("Clear Logo")
            Spacer()
          }
          .padding(.horizontal, 12).padding(.vertical, 9)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).foregroundStyle(.red)

        VStack(spacing: 2) {
          Text("LOGO SIZE & POSITION")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        }

        labeledSlider(
          label: "Width",
          value: $modelStore.draft.styles.logoWidth,
          range: 40...400, step: 5,
          display: "\(Int(modelStore.draft.styles.logoWidth)) pt"
        )

        labeledSlider(
          label: "Height",
          value: $modelStore.draft.styles.logoHeight,
          range: 20...200, step: 5,
          display: "\(Int(modelStore.draft.styles.logoHeight)) pt"
        )

        labeledSlider(
          label: "X Offset",
          value: $modelStore.draft.styles.logoX,
          range: 0...800, step: 5,
          display: "\(Int(modelStore.draft.styles.logoX)) pt"
        )

        labeledSlider(
          label: "Y Offset",
          value: $modelStore.draft.styles.logoY,
          range: 0...500, step: 5,
          display: "\(Int(modelStore.draft.styles.logoY)) pt"
        )
      }
    }
  }

  // MARK: - Layout Section

  private var layoutSliders: some View {
    Group {
      labeledSlider(
        label: "Columns",
        value: Binding(
          get: { Double(modelStore.draft.layouts.first?.columns ?? 8) },
          set: { v in
            guard !modelStore.draft.layouts.isEmpty else { return }
            modelStore.draft.layouts[0].columns = Int(v)
          }
        ),
        range: 2...48, step: 1,
        display: "\(modelStore.draft.layouts.first?.columns ?? 8)"
      )

      Picker("Fine grid (visual)", selection: $editorGridSubdivisions) {
        Text("Cells only").tag(1)
        Text("Half").tag(2)
        Text("Quarter").tag(4)
      }
      .pickerStyle(.segmented)

      labeledSlider(
        label: "Spacing",
        value: Binding(
          get: { modelStore.draft.layouts.first?.spacing ?? 10 },
          set: { v in
            guard !modelStore.draft.layouts.isEmpty else { return }
            modelStore.draft.layouts[0].spacing = v
          }
        ),
        range: 4...32, step: 1,
        display: "\(Int(modelStore.draft.layouts.first?.spacing ?? 10)) pt"
      )
    }
  }

  // MARK: - Effects Section

  private var effectSliders: some View {
    Group {
      labeledSlider(
        label: "Glow",
        value: Binding(
          get: { modelStore.draft.styles.glowOpacity },
          set: { modelStore.draft.styles.glowOpacity = $0 }
        ),
        range: 0...0.9, step: 0.05,
        display: "\(Int(modelStore.draft.styles.glowOpacity * 100))%"
      )

      labeledSlider(
        label: "Shadow Blur",
        value: Binding(
          get: { modelStore.draft.styles.shadowBlur },
          set: { modelStore.draft.styles.shadowBlur = $0 }
        ),
        range: 0...20, step: 1,
        display: "\(Int(modelStore.draft.styles.shadowBlur)) pt"
      )

      labeledSlider(
        label: "Shadow Offset",
        value: Binding(
          get: { modelStore.draft.styles.shadowY },
          set: { modelStore.draft.styles.shadowY = $0 }
        ),
        range: 0...12, step: 1,
        display: "\(Int(modelStore.draft.styles.shadowY)) pt"
      )
    }
  }

  @ViewBuilder
  private func labeledSlider(
    label: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    step: Double,
    display: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(label)
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer()
        Text(display)
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Slider(value: value, in: range, step: step)
        .tint(.blue)
    }
    .padding(.horizontal, 4)
  }

  // MARK: - Publish Section

  private var confirmButtons: some View {
    VStack(spacing: 8) {
      Button { confirmAndPublish() } label: {
        Label("Confirm & Publish", systemImage: "checkmark.circle.fill")
          .frame(maxWidth: .infinity)
          .padding(.vertical, 9)
          .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
      }
      .buttonStyle(.plain)
      .foregroundStyle(.green)

      Button {
        Task {
          do {
            try await modelStore.saveDraft()
            alertMessage = AlertMessage(message: "Draft saved.")
          } catch {
            alertMessage = AlertMessage(message: "Save failed: \(error.localizedDescription)")
          }
        }
      } label: {
        Label("Save Draft", systemImage: "square.and.arrow.down")
          .frame(maxWidth: .infinity)
          .padding(.vertical, 9)
          .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
      }
      .buttonStyle(.plain)
      .foregroundStyle(.blue)

      if !modelStore.validationErrors.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(modelStore.validationErrors, id: \.self) { err in
            Label(err, systemImage: "exclamationmark.triangle.fill")
              .font(.caption2)
              .foregroundStyle(.orange)
          }
        }
        .padding(.horizontal, 4)
      }
    }
  }

  // MARK: - Actions

  private func confirmAndPublish() {
    Task {
      do {
        try await modelStore.saveDraft()
        let ok = modelStore.publishDraft()
        alertMessage = AlertMessage(
          message: ok
            ? "Published. Controls are now live."
            : "Publish failed. Check device/command bindings."
        )
      } catch {
        alertMessage = AlertMessage(message: "Save failed: \(error.localizedDescription)")
      }
    }
  }

  private func appendControl(type: ControlType) {
    let columns = modelStore.draft.layouts.first?.columns ?? 8
    let count = modelStore.draft.controls.count
    let w: Int = {
      switch type {
      case .label: return 3
      case .icon: return 1
      case .border: return 4
      case .matrix: return 6
      case .liveMatrix: return 8
      case .volumeLevel: return 3
      default: return 2
      }
    }()
    let h: Int = {
      switch type {
      case .border: return 2
      case .matrix: return 4
      case .liveMatrix: return 5
      case .volumeLevel: return 2
      default: return 1
      }
    }()
    let usesFullRow = type == .matrix || type == .liveMatrix
    let x = usesFullRow ? 0 : (count * 2) % columns
    let y = usesFullRow ? 0 : (count * 2) / columns

    let binding: ControlBinding? = {
      if type == .label || type == .border { return nil }
      let deviceID = modelStore.draft.devices.first?.id ?? UUID()
      if type == .volumeLevel {
        return .init(deviceID: deviceID, commandID: UUID())
      }
      let commandID = modelStore.draft.commands.first?.id ?? UUID()
      return .init(deviceID: deviceID, commandID: commandID)
    }()

    var customFields: [String: String] = [:]
    if type == .icon {
      customFields["iconOn"] = "power.circle.fill"
      customFields["iconOff"] = "power.circle"
      customFields["iconSize"] = "44"
      customFields["iconColorOn"] = "green"
      customFields["iconColorOff"] = "gray"
    } else if type == .matrix {
      customFields["matrixInputCount"] = "4"
      customFields["matrixOutputCount"] = "4"
      customFields["matrixCommandTemplate"] = "{output} VS {input}"
      customFields["matrixLineEnding"] = "crlf"
      customFields["matrixTimeoutMs"] = "1500"
      customFields["matrixInputPrefix"] = "IN"
      customFields["matrixOutputPrefix"] = "OUT"
      customFields["matrixChipWidth"] = "80"
      customFields["matrixChipHeight"] = "52"
      customFields["matrixChipSpacing"] = "6"
      customFields["matrixTitleChipSpacing"] = "10"
      customFields["matrixSectionSpacing"] = "8"
      customFields["matrixFontSize"] = "14"
      customFields["matrixTitleFontSize"] = "11"
      customFields["matrixFontWeight"] = "semibold"
      customFields["matrixInputColor"] = "blue"
      customFields["matrixOutputColor"] = "green"
      customFields["matrixTextColor"] = "white"
    } else if type == .liveMatrix {
      customFields["liveMatrixInputCount"] = "4"
      customFields["liveMatrixOutputCount"] = "4"
      customFields["liveMatrixCommandTemplate"] = "matrix aset :av {input} {output}"
      customFields["liveMatrixLineEnding"] = "crlf"
      customFields["liveMatrixTimeoutMs"] = "1500"
      customFields["liveMatrixInputPrefix"] = "Tx"
      customFields["liveMatrixOutputPrefix"] = "Rx"
      customFields["liveMatrixChipWidth"] = "160"
      customFields["liveMatrixChipHeight"] = "120"
      customFields["liveMatrixOutputChipWidth"] = "160"
      customFields["liveMatrixOutputChipHeight"] = "120"
      customFields["liveMatrixChipSpacing"] = "8"
      customFields["liveMatrixTitleChipSpacing"] = "8"
      customFields["liveMatrixFontSize"] = "12"
      customFields["liveMatrixTitleFontSize"] = "12"
      customFields["liveMatrixFontWeight"] = "semibold"
      customFields["liveMatrixStreamServerHost"] = ""
      customFields["liveMatrixStreamServerPort"] = "10085"
      customFields["liveMatrixStreamWidth"] = "960"
      customFields["liveMatrixStreamHeight"] = "540"
      customFields["liveMatrixStreamFps"] = "30"
      customFields["liveMatrixStreamBw"] = "8000"
      customFields["liveMatrixStreamAs"] = "0"
    } else if type == .volumeLevel {
      customFields["volumeLevelCount"] = "8"
      customFields["volumeDefaultPosition"] = "center"
      customFields["volumeTitlePosition"] = "top"
      customFields["volumeActiveColor"] = "green"
      customFields["volumeInactiveColor"] = "gray"
      customFields["volumeLevelVisibility"] = "visible"
    } else if type == .border {
      customFields["borderThickness"] = "2"
      customFields["borderCornerRadius"] = "12"
      customFields["borderColorMode"] = "solid"
      customFields["borderColor"] = "#FFFFFF"
      customFields["borderGradientFrom"] = "#FFFFFF"
      customFields["borderGradientTo"] = "#0080FF"
      customFields["borderGradientAngle"] = "0"
    }

    let control = ControlItem(
      type: type,
      title: type == .label ? "Label \(count + 1)" : (type == .volumeLevel ? L10n.volumeLevelTitle : "\(typeLabel(type)) \(count + 1)"),
      behavior: type == .icon ? .toggle : (type == .button || type == .volumeLevel || type == .border ? .momentary : .toggle),
      binding: binding,
      placement: .init(x: Double(x), y: Double(y), w: Double(w), h: Double(h)),
      customFields: customFields
    )
    modelStore.draft.controls.append(control)
    selectedControlID = control.id
    editingControl = control
  }

  private func deleteControl(_ control: ControlItem) {
    let pid = control.id.uuidString
    let isMatrixParent = control.type == .matrix || control.type == .liveMatrix
    let chipTypes: Set<ControlType> = control.type == .liveMatrix
      ? [.liveMatrixInput, .liveMatrixOutput]
      : [.matrixInput, .matrixOutput]

    let removedIDs: [UUID] = modelStore.draft.controls.compactMap { c in
      if c.id == control.id { return c.id }
      if isMatrixParent,
         chipTypes.contains(c.type),
         c.customFields["parentControlID"] == pid {
        return c.id
      }
      return nil
    }
    let removedSet = Set(removedIDs)
    modelStore.draft.controls.removeAll { removedSet.contains($0.id) }
    if let selected = selectedControlID, removedSet.contains(selected) {
      selectedControlID = nil
    }
    if isMatrixParent {
      expandedMatrixParents.remove(pid)
    }
  }

  private func duplicateControl(_ control: ControlItem) {
    let newID = UUID()
    let newIDString = newID.uuidString
    let columns = Double(modelStore.draft.layouts.first?.columns ?? 8)

    // Offset the copy one row down; clamp to grid bounds.
    var newPlacement = control.placement
    newPlacement.y += 1

    var copy = control
    copy.id = newID
    copy.title = control.title + " Copy"
    copy.placement = newPlacement
    modelStore.draft.controls.append(copy)

    // For matrix/liveMatrix parents that have been exploded to chips,
    // also duplicate all chip children and re-wire their parentControlID.
    let isMatrixParent = control.type == .matrix || control.type == .liveMatrix
    if isMatrixParent && control.isExplodedMatrixParentHiddenFromCanvas {
      let oldPID = control.id.uuidString
      let chipTypes: Set<ControlType> = control.type == .liveMatrix
        ? [.liveMatrixInput, .liveMatrixOutput]
        : [.matrixInput, .matrixOutput]

      let chips = modelStore.draft.controls.filter {
        chipTypes.contains($0.type) && $0.customFields["parentControlID"] == oldPID
      }
      for chip in chips {
        var newChip = chip
        newChip.id = UUID()
        newChip.customFields["parentControlID"] = newIDString
        newChip.placement.y += 1
        newChip.placement.x = min(newChip.placement.x, columns - newChip.placement.w)
        modelStore.draft.controls.append(newChip)
      }

      // Update the saved origin keys in the parent copy so chip re-layout is correct.
      if let idx = modelStore.draft.controls.firstIndex(where: { $0.id == newID }) {
        if let ox = Double(modelStore.draft.controls[idx].customFields[ControlItem.matrixExplodeOriginXKey] ?? "") {
          modelStore.draft.controls[idx].customFields[ControlItem.matrixExplodeOriginXKey] = "\(Int(ox))"
        }
        if let oy = Double(modelStore.draft.controls[idx].customFields[ControlItem.matrixExplodeOriginYKey] ?? "") {
          modelStore.draft.controls[idx].customFields[ControlItem.matrixExplodeOriginYKey] = "\(Int(oy + 1))"
        }
      }
    }

    selectedControlID = newID
  }

  private func explodeToChips(_ parent: ControlItem) {
    if parent.isExplodedMatrixParentHiddenFromCanvas { return }
    let parentID = parent.id.uuidString
    let columns = modelStore.draft.layouts.first?.columns ?? 8
    let isLive = parent.type == .liveMatrix
    let prefix = isLive ? "liveMatrix" : "matrix"

    let inputCount = max(1, Int(parent.customFields["\(prefix)InputCount"] ?? "") ?? 4)
    let outputCount = max(1, Int(parent.customFields["\(prefix)OutputCount"] ?? "") ?? 4)
    let inputNames = MatrixNamesHelper.parseNames(
      parent.customFields["\(prefix)InputNames"], count: inputCount,
      prefix: parent.customFields["\(prefix)InputPrefix"] ?? (isLive ? "Tx" : "IN"))
    let outputNames = MatrixNamesHelper.parseNames(
      parent.customFields["\(prefix)OutputNames"], count: outputCount,
      prefix: parent.customFields["\(prefix)OutputPrefix"] ?? (isLive ? "Rx" : "OUT"))
    let inCmdPrefix = parent.customFields["\(prefix)InputPrefix"] ?? (isLive ? "Tx" : "IN")
    let outCmdPrefix = parent.customFields["\(prefix)OutputPrefix"] ?? (isLive ? "Rx" : "OUT")
    let inputCmds = isLive
      ? MatrixNamesHelper.parseCmds(parent.customFields["\(prefix)InputCmds"], count: inputCount)
      : MatrixNamesHelper.parseCmds(parent.customFields["\(prefix)InputCmds"], count: inputCount, idPrefix: inCmdPrefix)
    let outputCmds = isLive
      ? MatrixNamesHelper.parseCmds(parent.customFields["\(prefix)OutputCmds"], count: outputCount)
      : MatrixNamesHelper.parseCmds(parent.customFields["\(prefix)OutputCmds"], count: outputCount, idPrefix: outCmdPrefix)

    let defInW = isLive ? CGFloat(Double(parent.customFields["liveMatrixChipWidth"] ?? "") ?? 160)
                        : CGFloat(Double(parent.customFields["matrixChipWidth"] ?? "") ?? 80)
    let defInH = isLive ? CGFloat(Double(parent.customFields["liveMatrixChipHeight"] ?? "") ?? 120)
                        : CGFloat(Double(parent.customFields["matrixChipHeight"] ?? "") ?? 52)
    let defOutW = isLive ? CGFloat(Double(parent.customFields["liveMatrixOutputChipWidth"] ?? "") ?? Double(defInW))
                         : defInW
    let defOutH = isLive ? CGFloat(Double(parent.customFields["liveMatrixOutputChipHeight"] ?? "") ?? Double(defInH))
                         : defInH

    let inWs = isLive
      ? MatrixNamesHelper.parseSizes(parent.customFields["liveMatrixInputWidths"], count: inputCount, fallback: defInW)
      : MatrixNamesHelper.parseSizes(parent.customFields["matrixInputWidths"], count: inputCount, fallback: defInW)
    let inHs = isLive
      ? MatrixNamesHelper.parseSizes(parent.customFields["liveMatrixInputHeights"], count: inputCount, fallback: defInH)
      : MatrixNamesHelper.parseSizes(parent.customFields["matrixInputHeights"], count: inputCount, fallback: defInH)
    let outWs = isLive
      ? MatrixNamesHelper.parseSizes(
        parent.customFields["liveMatrixOutputWidths"], count: outputCount, fallback: defOutW)
      : MatrixNamesHelper.parseSizes(
        parent.customFields["matrixOutputWidths"], count: outputCount, fallback: defOutW)
    let outHs = isLive
      ? MatrixNamesHelper.parseSizes(
        parent.customFields["liveMatrixOutputHeights"], count: outputCount, fallback: defOutH)
      : MatrixNamesHelper.parseSizes(
        parent.customFields["matrixOutputHeights"], count: outputCount, fallback: defOutH)

    let baseY = Int(parent.placement.y.rounded())
    var curX = Int(parent.placement.x.rounded())

    let chipType: (Bool) -> ControlType = { isInput in
      isLive ? (isInput ? .liveMatrixInput : .liveMatrixOutput)
             : (isInput ? .matrixInput : .matrixOutput)
    }

    for i in 0..<inputCount {
      var cf: [String: String] = [:]
      cf["parentControlID"] = parentID
      cf["parentTitle"] = parent.title
      cf["chipIndex"] = "\(i)"
      cf["chipName"] = inputNames[i]
      cf["chipCmd"] = inputCmds[i]
      cf["chipWidth"] = "\(Int(inWs[i]))"
      cf["chipHeight"] = "\(Int(inHs[i]))"
      if isLive {
        let ips = parseJSONStringArrayStatic(parent.customFields["liveMatrixInputStreamIPs"], count: inputCount)
        let ports = parseJSONStringArrayStatic(parent.customFields["liveMatrixInputStreamPorts"], count: inputCount, fallback: "8080")
        let devIDs = parseJSONStringArrayStatic(parent.customFields["liveMatrixInputStreamDevIDs"], count: inputCount)
        cf["streamIP"] = ips[i]
        cf["streamPort"] = ports[i]
        cf["streamDevID"] = devIDs[i]
      }
      let w = max(1, Int(ceil(inWs[i] / max(CGFloat(columns) * 10, 1))))
      let h = max(1, Int(ceil(inHs[i] / max(CGFloat(columns) * 10, 1))))
      let chip = ControlItem(
        type: chipType(true),
        title: inputNames[i],
        binding: parent.binding,
        placement: .init(x: Double(min(curX, columns - w)), y: Double(baseY), w: Double(max(w, 2)), h: Double(max(h, 2))),
        customFields: cf
      )
      modelStore.draft.controls.append(chip)
      curX += max(w, 2)
      if curX >= columns { curX = 0 }
    }

    let outBaseY = baseY + 3
    curX = Int(parent.placement.x.rounded())
    for i in 0..<outputCount {
      var cf: [String: String] = [:]
      cf["parentControlID"] = parentID
      cf["parentTitle"] = parent.title
      cf["chipIndex"] = "\(i)"
      cf["chipName"] = outputNames[i]
      cf["chipCmd"] = outputCmds[i]
        cf["chipWidth"] = "\(Int(outWs[i]))"
        cf["chipHeight"] = "\(Int(outHs[i]))"
        let w = max(1, Int(ceil(outWs[i] / max(CGFloat(columns) * 10, 1))))
      let h = max(1, Int(ceil(outHs[i] / max(CGFloat(columns) * 10, 1))))
      let chip = ControlItem(
        type: chipType(false),
        title: outputNames[i],
        binding: parent.binding,
        placement: .init(x: Double(min(curX, columns - w)), y: Double(outBaseY), w: Double(max(w, 2)), h: Double(max(h, 2))),
        customFields: cf
      )
      modelStore.draft.controls.append(chip)
      curX += max(w, 2)
      if curX >= columns { curX = 0 }
    }

    if let idx = modelStore.draft.controls.firstIndex(where: { $0.id == parent.id }) {
      modelStore.draft.controls[idx].customFields[ControlItem.matrixExplodedToChipsKey] = "1"
      // Store as integer cell origin for the chip layout cursor.
      modelStore.draft.controls[idx].customFields[ControlItem.matrixExplodeOriginXKey] = "\(Int(parent.placement.x.rounded()))"
      modelStore.draft.controls[idx].customFields[ControlItem.matrixExplodeOriginYKey] = "\(Int(parent.placement.y.rounded()))"
      modelStore.draft.controls[idx].placement = .init(x: 0, y: 0, w: 0, h: 0)
    }
  }

  private func parseJSONStringArrayStatic(_ json: String?, count: Int, fallback: String = "") -> [String] {
    guard let json, let data = json.data(using: .utf8),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
    else { return Array(repeating: fallback, count: count) }
    var result = arr
    while result.count < count { result.append(fallback) }
    return result
  }

  private func snapControl(_ id: UUID, toX: Double, toY: Double) {
    guard let idx = modelStore.draft.controls.firstIndex(where: { $0.id == id }) else { return }
    modelStore.draft.controls[idx].placement.x = toX
    modelStore.draft.controls[idx].placement.y = toY
  }

  private func resizeControl(_ id: UUID, toW: Double, toH: Double) {
    guard let idx = modelStore.draft.controls.firstIndex(where: { $0.id == id }) else { return }
    modelStore.draft.controls[idx].placement.w = toW
    modelStore.draft.controls[idx].placement.h = toH
  }


  private func applyControlUpdate(_ updated: ControlItem) {
    if let idx = modelStore.draft.controls.firstIndex(where: { $0.id == updated.id }) {
      let previous = modelStore.draft.controls[idx]
      var normalized = updated
      if updated.type.isMatrixChip,
         let chipName = updated.customFields["chipName"],
         !chipName.isEmpty {
        normalized.title = chipName
      }
      modelStore.draft.controls[idx] = normalized
      if updated.isExplodedMatrixParentHiddenFromCanvas
        && (updated.type == .matrix || updated.type == .liveMatrix) {
        appendNewMatrixChipsForIncreasedIONames(previous: previous, updated: updated)
      }
      if updated.type == .matrix || updated.type == .liveMatrix {
        syncMatrixChildChipDimensionsFromParent(updated)
        syncMatrixChildChipNamesFromParent(updated)
        if updated.type == .liveMatrix {
          syncMatrixChildStreamFromParent(updated)
        }
      }
      let chipTypes: Set<ControlType> = [.matrixInput, .matrixOutput, .liveMatrixInput, .liveMatrixOutput]
      if chipTypes.contains(normalized.type) {
        let prevName = previous.customFields["chipName"] ?? previous.title
        let newName  = normalized.customFields["chipName"] ?? normalized.title
        if prevName != newName {
          syncChipNameToParent(normalized)
        }
        let prevCmd = previous.customFields["chipCmd"] ?? ""
        let newCmd = normalized.customFields["chipCmd"] ?? ""
        if prevCmd != newCmd {
          syncChipCmdToParent(normalized)
        }
        if normalized.type == .liveMatrixInput {
          let streamChanged =
            previous.customFields["streamIP"] != normalized.customFields["streamIP"]
            || previous.customFields["streamPort"] != normalized.customFields["streamPort"]
            || previous.customFields["streamDevID"] != normalized.customFields["streamDevID"]
          if streamChanged {
            syncChipStreamToParent(normalized)
          }
        }
      }
    }
  }

  /// When a chip's name is edited directly, write it back into the parent's name JSON array
  /// so the parent's input/output name list stays consistent.
  private func syncChipNameToParent(_ chip: ControlItem) {
    guard
      let parentIDStr = chip.customFields["parentControlID"],
      let chipIdx = Int(chip.customFields["chipIndex"] ?? ""),
      let parentIdx = modelStore.draft.controls.firstIndex(where: { $0.id.uuidString == parentIDStr })
    else { return }

    var parent = modelStore.draft.controls[parentIdx]
    let isLive  = chip.type == .liveMatrixInput || chip.type == .liveMatrixOutput
    let isInput = chip.type == .matrixInput     || chip.type == .liveMatrixInput
    let prefix  = isLive ? "liveMatrix" : "matrix"
    let nameKey  = isInput ? "\(prefix)InputNames"  : "\(prefix)OutputNames"
    let countKey = isInput ? "\(prefix)InputCount"  : "\(prefix)OutputCount"
    let namePrefix = isInput
      ? (parent.customFields["\(prefix)InputPrefix"]  ?? (isLive ? "Tx" : "IN"))
      : (parent.customFields["\(prefix)OutputPrefix"] ?? (isLive ? "Rx" : "OUT"))
    let count = max(1, Int(parent.customFields[countKey] ?? "") ?? 4)
    let newName = chip.customFields["chipName"] ?? chip.title

    var names = MatrixNamesHelper.parseNames(parent.customFields[nameKey], count: count, prefix: namePrefix)
    guard chipIdx >= 0, chipIdx < names.count else { return }
    names[chipIdx] = newName

    if let data = try? JSONSerialization.data(withJSONObject: names),
       let json = String(data: data, encoding: .utf8) {
      parent.customFields[nameKey] = json
      modelStore.draft.controls[parentIdx] = parent
    }
  }

  /// When a chip's route ID is edited, write it back into the parent's cmd JSON array.
  private func syncChipCmdToParent(_ chip: ControlItem) {
    guard
      let parentIDStr = chip.customFields["parentControlID"],
      let chipIdx = Int(chip.customFields["chipIndex"] ?? ""),
      let parentIdx = modelStore.draft.controls.firstIndex(where: { $0.id.uuidString == parentIDStr })
    else { return }

    var parent = modelStore.draft.controls[parentIdx]
    let isLive = chip.type == .liveMatrixInput || chip.type == .liveMatrixOutput
    let isInput = chip.type == .matrixInput || chip.type == .liveMatrixInput
    let prefix = isLive ? "liveMatrix" : "matrix"
    let cmdKey = isInput ? "\(prefix)InputCmds" : "\(prefix)OutputCmds"
    let countKey = isInput ? "\(prefix)InputCount" : "\(prefix)OutputCount"
    let count = max(1, Int(parent.customFields[countKey] ?? "") ?? 4)
    let idPrefix = isInput
      ? (parent.customFields["\(prefix)InputPrefix"] ?? (isLive ? "Tx" : "IN"))
      : (parent.customFields["\(prefix)OutputPrefix"] ?? (isLive ? "Rx" : "OUT"))
    let newCmd = chip.customFields["chipCmd"] ?? (isLive ? "\(chipIdx)" : "\(idPrefix)\(chipIdx + 1)")

    var cmds = isLive
      ? MatrixNamesHelper.parseCmds(parent.customFields[cmdKey], count: count)
      : MatrixNamesHelper.parseCmds(parent.customFields[cmdKey], count: count, idPrefix: idPrefix)
    guard chipIdx >= 0, chipIdx < cmds.count else { return }
    cmds[chipIdx] = newCmd

    if let data = try? JSONSerialization.data(withJSONObject: cmds),
       let json = String(data: data, encoding: .utf8) {
      parent.customFields[cmdKey] = json
      modelStore.draft.controls[parentIdx] = parent
    }
  }

  /// When a live input chip's stream fields are edited, write them back to the parent arrays.
  private func syncChipStreamToParent(_ chip: ControlItem) {
    guard chip.type == .liveMatrixInput,
          let parentIDStr = chip.customFields["parentControlID"],
          let chipIdx = Int(chip.customFields["chipIndex"] ?? ""),
          let parentIdx = modelStore.draft.controls.firstIndex(where: { $0.id.uuidString == parentIDStr })
    else { return }

    var parent = modelStore.draft.controls[parentIdx]
    let inCount = max(1, Int(parent.customFields["liveMatrixInputCount"] ?? "") ?? 4)
    guard chipIdx >= 0, chipIdx < inCount else { return }

    func writeJSONArray(key: String, value: String, fallback: String = "") {
      var arr = parseJSONStringArrayStatic(parent.customFields[key], count: inCount, fallback: fallback)
      arr[chipIdx] = value
      if let data = try? JSONSerialization.data(withJSONObject: arr),
         let json = String(data: data, encoding: .utf8) {
        parent.customFields[key] = json
      }
    }

    writeJSONArray(key: "liveMatrixInputStreamIPs", value: chip.customFields["streamIP"] ?? "")
    writeJSONArray(
      key: "liveMatrixInputStreamPorts",
      value: chip.customFields["streamPort"] ?? "8080",
      fallback: "8080"
    )
    writeJSONArray(key: "liveMatrixInputStreamDevIDs", value: chip.customFields["streamDevID"] ?? "")
    modelStore.draft.controls[parentIdx] = parent
  }

  /// Syncs child chip names and titles from the parent's name/cmd lists.
  /// Only updates chips whose name still matches the previous parent-derived name
  /// (i.e. not manually customised by the user).
  private func syncMatrixChildChipNamesFromParent(_ parent: ControlItem) {
    guard parent.type == .matrix || parent.type == .liveMatrix else { return }
    let isLive = parent.type == .liveMatrix
    let prefix = isLive ? "liveMatrix" : "matrix"
    let inCount = max(1, Int(parent.customFields["\(prefix)InputCount"] ?? "") ?? 4)
    let outCount = max(1, Int(parent.customFields["\(prefix)OutputCount"] ?? "") ?? 4)

    let inNamePrefix = parent.customFields["\(prefix)InputPrefix"] ?? (isLive ? "Tx" : "IN")
    let outNamePrefix = parent.customFields["\(prefix)OutputPrefix"] ?? (isLive ? "Rx" : "OUT")
    let inNames = MatrixNamesHelper.parseNames(
      parent.customFields["\(prefix)InputNames"], count: inCount,
      prefix: inNamePrefix)
    let outNames = MatrixNamesHelper.parseNames(
      parent.customFields["\(prefix)OutputNames"], count: outCount,
      prefix: outNamePrefix)
    let inCmds = isLive
      ? MatrixNamesHelper.parseCmds(parent.customFields["\(prefix)InputCmds"], count: inCount)
      : MatrixNamesHelper.parseCmds(parent.customFields["\(prefix)InputCmds"], count: inCount, idPrefix: inNamePrefix)
    let outCmds = isLive
      ? MatrixNamesHelper.parseCmds(parent.customFields["\(prefix)OutputCmds"], count: outCount)
      : MatrixNamesHelper.parseCmds(parent.customFields["\(prefix)OutputCmds"], count: outCount, idPrefix: outNamePrefix)

    let parentID = parent.id.uuidString
    for i in modelStore.draft.controls.indices {
      var c = modelStore.draft.controls[i]
      guard c.customFields["parentControlID"] == parentID else { continue }
      let idx = Int(c.customFields["chipIndex"] ?? "") ?? 0
      if isLive {
        if c.type == .liveMatrixInput, idx >= 0, idx < inCount {
          c.customFields["chipName"] = inNames[idx]
          c.customFields["chipCmd"] = inCmds[idx]
          c.customFields["parentTitle"] = parent.title
          c.title = inNames[idx]
          modelStore.draft.controls[i] = c
        } else if c.type == .liveMatrixOutput, idx >= 0, idx < outCount {
          c.customFields["chipName"] = outNames[idx]
          c.customFields["chipCmd"] = outCmds[idx]
          c.customFields["parentTitle"] = parent.title
          c.title = outNames[idx]
          modelStore.draft.controls[i] = c
        }
      } else {
        if c.type == .matrixInput, idx >= 0, idx < inCount {
          c.customFields["chipName"] = inNames[idx]
          c.customFields["chipCmd"] = inCmds[idx]
          c.customFields["parentTitle"] = parent.title
          c.title = inNames[idx]
          modelStore.draft.controls[i] = c
        } else if c.type == .matrixOutput, idx >= 0, idx < outCount {
          c.customFields["chipName"] = outNames[idx]
          c.customFields["chipCmd"] = outCmds[idx]
          c.customFields["parentTitle"] = parent.title
          c.title = outNames[idx]
          modelStore.draft.controls[i] = c
        }
      }
    }
  }

  /// Copies parent live-matrix stream device fields onto exploded input chips.
  private func syncMatrixChildStreamFromParent(_ parent: ControlItem) {
    guard parent.type == .liveMatrix else { return }
    let inCount = max(1, Int(parent.customFields["liveMatrixInputCount"] ?? "") ?? 4)
    let ips = parseJSONStringArrayStatic(parent.customFields["liveMatrixInputStreamIPs"], count: inCount)
    let ports = parseJSONStringArrayStatic(
      parent.customFields["liveMatrixInputStreamPorts"], count: inCount, fallback: "8080")
    let devIDs = parseJSONStringArrayStatic(
      parent.customFields["liveMatrixInputStreamDevIDs"], count: inCount)

    let parentID = parent.id.uuidString
    for i in modelStore.draft.controls.indices {
      var c = modelStore.draft.controls[i]
      guard c.customFields["parentControlID"] == parentID,
            c.type == .liveMatrixInput else { continue }
      let idx = Int(c.customFields["chipIndex"] ?? "") ?? 0
      guard idx >= 0, idx < inCount else { continue }
      c.customFields["streamIP"] = ips[idx]
      c.customFields["streamPort"] = ports[idx]
      c.customFields["streamDevID"] = devIDs[idx]
      modelStore.draft.controls[i] = c
    }
  }

  /// Syncs child chip placement (grid cells) from the parent's Chip Style and per-index sizes.
  private func syncMatrixChildChipDimensionsFromParent(_ parent: ControlItem) {
    guard parent.type == .matrix || parent.type == .liveMatrix else { return }
    let isLive = parent.type == .liveMatrix
    let prefix = isLive ? "liveMatrix" : "matrix"
    let inCount = max(1, Int(parent.customFields["\(prefix)InputCount"] ?? "") ?? 4)
    let outCount = max(1, Int(parent.customFields["\(prefix)OutputCount"] ?? "") ?? 4)

    let defInW = isLive
      ? CGFloat(Double(parent.customFields["liveMatrixChipWidth"] ?? "") ?? 160)
      : CGFloat(Double(parent.customFields["matrixChipWidth"] ?? "") ?? 80)
    let defInH = isLive
      ? CGFloat(Double(parent.customFields["liveMatrixChipHeight"] ?? "") ?? 120)
      : CGFloat(Double(parent.customFields["matrixChipHeight"] ?? "") ?? 52)
    let defOutW = isLive
      ? CGFloat(Double(parent.customFields["liveMatrixOutputChipWidth"] ?? "") ?? Double(defInW))
      : defInW
    let defOutH = isLive
      ? CGFloat(Double(parent.customFields["liveMatrixOutputChipHeight"] ?? "") ?? Double(defInH))
      : defInH

    let inW: [CGFloat]
    let inH: [CGFloat]
    let outW: [CGFloat]
    let outH: [CGFloat]
    if isLive {
      inW = MatrixNamesHelper.parseSizes(parent.customFields["liveMatrixInputWidths"], count: inCount, fallback: defInW)
      inH = MatrixNamesHelper.parseSizes(parent.customFields["liveMatrixInputHeights"], count: inCount, fallback: defInH)
      outW = MatrixNamesHelper.parseSizes(
        parent.customFields["liveMatrixOutputWidths"], count: outCount, fallback: defOutW)
      outH = MatrixNamesHelper.parseSizes(
        parent.customFields["liveMatrixOutputHeights"], count: outCount, fallback: defOutH)
    } else {
      inW = MatrixNamesHelper.parseSizes(parent.customFields["matrixInputWidths"], count: inCount, fallback: defInW)
      inH = MatrixNamesHelper.parseSizes(parent.customFields["matrixInputHeights"], count: inCount, fallback: defInH)
      outW = MatrixNamesHelper.parseSizes(parent.customFields["matrixOutputWidths"], count: outCount, fallback: defOutW)
      outH = MatrixNamesHelper.parseSizes(parent.customFields["matrixOutputHeights"], count: outCount, fallback: defOutH)
    }


    // Convert point-based sizes to grid cells using current canvas geometry.
    let columns = max(1, modelStore.draft.layouts.first?.columns ?? 8)
    let cellSize = max(1, modelStore.runtimeCanvasSize.width / CGFloat(columns))
    func gw(_ pts: CGFloat) -> Double { max(1.0, Double(ceil(pts / cellSize))) }
    func gh(_ pts: CGFloat) -> Double { max(1.0, Double(ceil(pts / cellSize))) }

    let parentID = parent.id.uuidString
    for i in modelStore.draft.controls.indices {
      var c = modelStore.draft.controls[i]
      guard c.customFields["parentControlID"] == parentID else { continue }
      let idx = Int(c.customFields["chipIndex"] ?? "") ?? 0
      if isLive {
        if c.type == .liveMatrixInput, idx >= 0, idx < inCount {
          c.placement.w = gw(inW[idx])
          c.placement.h = gh(inH[idx])
          modelStore.draft.controls[i] = c
        } else if c.type == .liveMatrixOutput, idx >= 0, idx < outCount {
          c.placement.w = gw(outW[idx])
          c.placement.h = gh(outH[idx])
          modelStore.draft.controls[i] = c
        }
      } else {
        if c.type == .matrixInput, idx >= 0, idx < inCount {
          c.placement.w = gw(inW[idx])
          c.placement.h = gh(inH[idx])
          modelStore.draft.controls[i] = c
        } else if c.type == .matrixOutput, idx >= 0, idx < outCount {
          c.placement.w = gw(outW[idx])
          c.placement.h = gh(outH[idx])
          modelStore.draft.controls[i] = c
        }
      }
    }
  }


  /// After editing an already-exploded matrix parent, add chips only for new input/output indices; existing chips are unchanged.
  private func appendNewMatrixChipsForIncreasedIONames(previous: ControlItem, updated: ControlItem) {
    let isLive = updated.type == .liveMatrix
    let prefix = isLive ? "liveMatrix" : "matrix"
    let oldIn = max(1, Int(previous.customFields["\(prefix)InputCount"] ?? "") ?? 4)
    let oldOut = max(1, Int(previous.customFields["\(prefix)OutputCount"] ?? "") ?? 4)
    let newIn = max(1, Int(updated.customFields["\(prefix)InputCount"] ?? "") ?? 4)
    let newOut = max(1, Int(updated.customFields["\(prefix)OutputCount"] ?? "") ?? 4)
    if newIn <= oldIn && newOut <= oldOut { return }

    let parentID = updated.id.uuidString
    let columns = modelStore.draft.layouts.first?.columns ?? 8

    let inNames = MatrixNamesHelper.parseNames(
      updated.customFields["\(prefix)InputNames"], count: newIn,
      prefix: updated.customFields["\(prefix)InputPrefix"] ?? (isLive ? "Tx" : "IN"))
    let outNames = MatrixNamesHelper.parseNames(
      updated.customFields["\(prefix)OutputNames"], count: newOut,
      prefix: updated.customFields["\(prefix)OutputPrefix"] ?? (isLive ? "Rx" : "OUT"))
    let inCmdPrefix = updated.customFields["\(prefix)InputPrefix"] ?? (isLive ? "Tx" : "IN")
    let outCmdPrefix = updated.customFields["\(prefix)OutputPrefix"] ?? (isLive ? "Rx" : "OUT")
    let inCmds = isLive
      ? MatrixNamesHelper.parseCmds(updated.customFields["\(prefix)InputCmds"], count: newIn)
      : MatrixNamesHelper.parseCmds(updated.customFields["\(prefix)InputCmds"], count: newIn, idPrefix: inCmdPrefix)
    let outCmds = isLive
      ? MatrixNamesHelper.parseCmds(updated.customFields["\(prefix)OutputCmds"], count: newOut)
      : MatrixNamesHelper.parseCmds(updated.customFields["\(prefix)OutputCmds"], count: newOut, idPrefix: outCmdPrefix)

    let defInW = isLive
      ? CGFloat(Double(updated.customFields["liveMatrixChipWidth"] ?? "") ?? 160)
      : CGFloat(Double(updated.customFields["matrixChipWidth"] ?? "") ?? 80)
    let defInH = isLive
      ? CGFloat(Double(updated.customFields["liveMatrixChipHeight"] ?? "") ?? 120)
      : CGFloat(Double(updated.customFields["matrixChipHeight"] ?? "") ?? 52)
    let defOutW = isLive
      ? CGFloat(Double(updated.customFields["liveMatrixOutputChipWidth"] ?? "") ?? Double(defInW))
      : defInW
    let defOutH = isLive
      ? CGFloat(Double(updated.customFields["liveMatrixOutputChipHeight"] ?? "") ?? Double(defInH))
      : defInH

    let inWs = isLive
      ? MatrixNamesHelper.parseSizes(updated.customFields["liveMatrixInputWidths"], count: newIn, fallback: defInW)
      : MatrixNamesHelper.parseSizes(updated.customFields["matrixInputWidths"], count: newIn, fallback: defInW)
    let inHs = isLive
      ? MatrixNamesHelper.parseSizes(updated.customFields["liveMatrixInputHeights"], count: newIn, fallback: defInH)
      : MatrixNamesHelper.parseSizes(updated.customFields["matrixInputHeights"], count: newIn, fallback: defInH)
    let outWs = isLive
      ? MatrixNamesHelper.parseSizes(
        updated.customFields["liveMatrixOutputWidths"], count: newOut, fallback: defOutW)
      : MatrixNamesHelper.parseSizes(
        updated.customFields["matrixOutputWidths"], count: newOut, fallback: defOutW)
    let outHs = isLive
      ? MatrixNamesHelper.parseSizes(
        updated.customFields["liveMatrixOutputHeights"], count: newOut, fallback: defOutH)
      : MatrixNamesHelper.parseSizes(
        updated.customFields["matrixOutputHeights"], count: newOut, fallback: defOutH)

    let originX: Int
    let originY: Int
    if let ox = Int(updated.customFields[ControlItem.matrixExplodeOriginXKey] ?? ""),
       let oy = Int(updated.customFields[ControlItem.matrixExplodeOriginYKey] ?? "") {
      originX = ox
      originY = oy
    } else {
      // Legacy: layout continues from a simulated grid (0,0) — may need manual nudge
      originX = 0
      originY = 0
    }

    let inputChipType: ControlType = isLive ? .liveMatrixInput : .matrixInput
    let outputChipType: ControlType = isLive ? .liveMatrixOutput : .matrixOutput

    if newIn > oldIn {
      var curX = advanceMatrixInputLayoutCursor(
        originX: originX, originY: originY, endIndex: oldIn,
        columns: columns, defInW: defInW)
      let baseY = originY
      for i in oldIn..<newIn {
        var cf: [String: String] = [:]
        cf["parentControlID"] = parentID
        cf["parentTitle"] = updated.title
        cf["chipIndex"] = "\(i)"
        cf["chipName"] = inNames[i]
        cf["chipCmd"] = inCmds[i]
        cf["chipWidth"] = "\(Int(inWs[i]))"
        cf["chipHeight"] = "\(Int(inHs[i]))"
        if isLive {
          let ips = parseJSONStringArrayStatic(updated.customFields["liveMatrixInputStreamIPs"], count: newIn)
          let ports = parseJSONStringArrayStatic(
            updated.customFields["liveMatrixInputStreamPorts"], count: newIn, fallback: "8080")
          let devIDs = parseJSONStringArrayStatic(
            updated.customFields["liveMatrixInputStreamDevIDs"], count: newIn)
          cf["streamIP"] = ips[i]
          cf["streamPort"] = ports[i]
          cf["streamDevID"] = devIDs[i]
        }
        let w = max(1, Int(ceil(inWs[i] / max(CGFloat(columns) * 10, 1))))
        let h = max(1, Int(ceil(inHs[i] / max(CGFloat(columns) * 10, 1))))
        let chip = ControlItem(
          type: inputChipType,
          title: inNames[i],
          binding: updated.binding,
          placement: .init(x: Double(min(curX, columns - w)), y: Double(baseY), w: Double(max(w, 2)), h: Double(max(h, 2))),
          customFields: cf
        )
        modelStore.draft.controls.append(chip)
        curX += max(w, 2)
        if curX >= columns { curX = 0 }
      }
    }

    if newOut > oldOut {
      let outBaseY = originY + 3
      var curX = advanceMatrixOutputLayoutCursor(
        originX: originX, outBaseY: outBaseY, endIndex: oldOut, columns: columns, defW: defOutW)
      for i in oldOut..<newOut {
        var cf: [String: String] = [:]
        cf["parentControlID"] = parentID
        cf["parentTitle"] = updated.title
        cf["chipIndex"] = "\(i)"
        cf["chipName"] = outNames[i]
        cf["chipCmd"] = outCmds[i]
        cf["chipWidth"] = "\(Int(outWs[i]))"
        cf["chipHeight"] = "\(Int(outHs[i]))"
        let w = max(1, Int(ceil(outWs[i] / max(CGFloat(columns) * 10, 1))))
        let h = max(1, Int(ceil(outHs[i] / max(CGFloat(columns) * 10, 1))))
        let chip = ControlItem(
          type: outputChipType,
          title: outNames[i],
          binding: updated.binding,
          placement: .init(x: Double(min(curX, columns - w)), y: Double(outBaseY), w: Double(max(w, 2)), h: Double(max(h, 2))),
          customFields: cf
        )
        modelStore.draft.controls.append(chip)
        curX += max(w, 2)
        if curX >= columns { curX = 0 }
      }
    }
  }

  private func advanceMatrixInputLayoutCursor(
    originX: Int, originY: Int, endIndex: Int, columns: Int, defInW: CGFloat
  ) -> Int {
    var curX = originX
    _ = originY
    for _ in 0..<endIndex {
      let w = max(1, Int(ceil(defInW / max(CGFloat(columns) * 10, 1))))
      curX += max(w, 2)
      if curX >= columns { curX = 0 }
    }
    return curX
  }

  private func advanceMatrixOutputLayoutCursor(
    originX: Int, outBaseY: Int, endIndex: Int, columns: Int, defW: CGFloat
  ) -> Int {
    var curX = originX
    _ = outBaseY
    for _ in 0..<endIndex {
      let w = max(1, Int(ceil(defW / max(CGFloat(columns) * 10, 1))))
      curX += max(w, 2)
      if curX >= columns { curX = 0 }
    }
    return curX
  }

  private func applyCommandUpdate(_ cmd: CommandItem) {
    if let idx = modelStore.draft.commands.firstIndex(where: { $0.id == cmd.id }) {
      modelStore.draft.commands[idx] = cmd
    } else {
      modelStore.draft.commands.append(cmd)
    }
  }

  private func saveImage(data: Data, prefix: String) throws -> String {
    let base =
      FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("AVSysMaster/images", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let file = base.appendingPathComponent("\(prefix)-\(UUID().uuidString).jpg")
    try data.write(to: file, options: .atomic)
    return file.path
  }

  private func typeIcon(_ type: ControlType) -> String {
    switch type {
    case .button: return "hand.tap"
    case .slider: return "slider.horizontal.3"
    case .toggle: return "switch.2"
    case .label: return "textformat"
    case .icon: return "power.circle"
    case .border: return "rectangle"
    case .matrix: return "rectangle.split.2x2"
    case .liveMatrix: return "video.badge.waveform"
    case .volumeLevel: return "slider.vertical.3"
    case .matrixInput: return "video.fill"
    case .matrixOutput: return "display"
    case .liveMatrixInput: return "video.fill"
    case .liveMatrixOutput: return "display"
    }
  }

  private func typeLabel(_ type: ControlType) -> String {
    switch type {
    case .button: return "Button"
    case .slider: return "Slider"
    case .toggle: return "Toggle"
    case .label: return "Label"
    case .icon: return "Icon Toggle"
    case .border: return "Border"
    case .matrix: return "Matrix"
    case .liveMatrix: return "Live Matrix"
    case .volumeLevel: return L10n.volumeLevelTitle
    case .matrixInput: return "Matrix Input"
    case .matrixOutput: return "Matrix Output"
    case .liveMatrixInput: return "LM Input"
    case .liveMatrixOutput: return "LM Output"
    }
  }
}

// MARK: - Placement Formatting Helper

/// Formats a Double cell-unit value: shows an integer when whole, one decimal otherwise.
private func fmtPlacement(_ v: Double) -> String {
  v.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(v))" : String(format: "%.1f", v)
}

// MARK: - Grid Lines

private struct GridLinesView: View {
  let columns: Int
  let cellW: CGFloat
  let cellH: CGFloat
  /// 1: same as one cell per snap unit; 2 or 4: draw fainter sub-lines (placement still whole cells)
  var subdivisions: Int = 2

  var body: some View {
    Canvas { context, size in
      let subs = max(1, min(subdivisions, 8))
      let stepX = cellW / CGFloat(subs)
      let stepY = cellH / CGFloat(subs)
      let nVert = columns * subs
      let nHorz = Int(ceil(size.height / stepY))

      for i in 0...nVert {
        let x = CGFloat(i) * stepX
        if x > size.width + 0.5 { break }
        let isMajor = (i % subs) == 0
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: size.height))
        let c = isMajor ? Color.gray.opacity(0.26) : Color.gray.opacity(0.11)
        let lw: CGFloat = isMajor ? 0.55 : 0.35
        context.stroke(path, with: .color(c), lineWidth: lw)
      }

      for j in 0...nHorz {
        let y = CGFloat(j) * stepY
        if y > size.height + 0.5 { break }
        let isMajor = (j % subs) == 0
        var path = Path()
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: CGFloat(columns) * cellW, y: y))
        let c = isMajor ? Color.gray.opacity(0.26) : Color.gray.opacity(0.11)
        let lw: CGFloat = isMajor ? 0.55 : 0.35
        context.stroke(path, with: .color(c), lineWidth: lw)
      }
    }
  }
}

// MARK: - Draggable Tile (with resize handle)

private struct DraggableTile: View {
  let control: ControlItem
  let cellW: CGFloat
  let cellH: CGFloat
  let columns: Int
  let rows: Int
  /// Snap resolution per cell: 1 = whole cell, 2 = half-cell, 4 = quarter-cell.
  var snapSubdivisions: Int = 1
  let isSelected: Bool
  let styles: StyleItem
  let onSnap: (Double, Double) -> Void
  let onResize: (Double, Double) -> Void
  let onTap: () -> Void
  let onDelete: () -> Void

  @EnvironmentObject private var modelStore: UnifiedModelStore

  @State private var dragOffset: CGSize = .zero
  @State private var isDragging = false
  @State private var resizeOffset: CGSize = .zero
  @State private var isResizing = false

  private var subCellW: CGFloat { cellW / CGFloat(max(1, snapSubdivisions)) }
  private var subCellH: CGFloat { cellH / CGFloat(max(1, snapSubdivisions)) }

  private var currentW: CGFloat {
    CGFloat(control.placement.w) * cellW + (isResizing ? resizeOffset.width : 0)
  }
  private var currentH: CGFloat {
    CGFloat(control.placement.h) * cellH + (isResizing ? resizeOffset.height : 0)
  }

  var body: some View {
    // Minimum tile display size is one sub-cell so controls can be set very small.
    let tileW = max(currentW, subCellW)
    let tileH = max(currentH, subCellH)
    let baseX = CGFloat(control.placement.x) * cellW + tileW / 2
    let baseY = CGFloat(control.placement.y) * cellH + tileH / 2

    ZStack(alignment: .bottomTrailing) {
      tileBody
        .frame(width: max(tileW - 6, 24), height: max(tileH - 6, 24))

      if isSelected {
        resizeHandle
      }
    }
    .frame(width: tileW, height: tileH)
    .position(x: baseX + dragOffset.width, y: baseY + dragOffset.height)
    .opacity(isDragging ? 0.75 : 1.0)
    .zIndex(isDragging || isResizing ? 100 : (isSelected ? 50 : 0))
    .gesture(
      DragGesture(minimumDistance: 10)
        .onChanged { value in
          guard !isResizing else { return }
          isDragging = true
          dragOffset = value.translation
        }
        .onEnded { value in
          guard !isResizing else { return }
          isDragging = false
          // Snap to sub-cell grid: step = 1/snapSubdivisions in cell units.
          let subStep = 1.0 / Double(max(1, snapSubdivisions))
          let originPixX = control.placement.x * Double(cellW)
          let originPixY = control.placement.y * Double(cellH)
          let newRawX = (originPixX + Double(value.translation.width)) / Double(subCellW)
          let newRawY = (originPixY + Double(value.translation.height)) / Double(subCellH)
          let snappedX = newRawX.rounded() * subStep
          let snappedY = newRawY.rounded() * subStep
          let clampedX = max(0.0, min(Double(columns) - control.placement.w, snappedX))
          let clampedY = max(0.0, min(Double(rows)   - control.placement.h, snappedY))
          dragOffset = .zero
          onSnap(clampedX, clampedY)
        }
    )
    .onTapGesture {
      onTap()
    }
  }

  // MARK: Resize Handle

  private var resizeHandle: some View {
    Image(systemName: "arrow.down.right.and.arrow.up.left")
      .font(.system(size: 11, weight: .bold))
      .foregroundStyle(.white)
      .frame(width: 26, height: 26)
      .background(Color.blue, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
      .padding(3)
      .highPriorityGesture(
        DragGesture(minimumDistance: 3)
          .onChanged { value in
            isResizing = true
            resizeOffset = value.translation
          }
          .onEnded { value in
            isResizing = false
            // Resize also snaps to the sub-cell grid.
            let subStep = 1.0 / Double(max(1, snapSubdivisions))
            let basePixW = control.placement.w * Double(cellW)
            let basePixH = control.placement.h * Double(cellH)
            let newRawW = (basePixW + Double(value.translation.width))  / Double(subCellW)
            let newRawH = (basePixH + Double(value.translation.height)) / Double(subCellH)
            let snappedW = newRawW.rounded() * subStep
            let snappedH = newRawH.rounded() * subStep
            let clampedW = max(subStep, min(Double(columns) - control.placement.x, snappedW))
            let clampedH = max(subStep, min(Double(rows)   - control.placement.y, snappedH))
            resizeOffset = .zero
            onResize(clampedW, clampedH)
          }
      )
  }

  // MARK: Tile Body

  private var tileBody: some View {
    ZStack(alignment: .topTrailing) {
      if control.type == .label {
        labelPreview
      } else if control.type == .icon {
        iconPreview
      } else if control.type == .toggle {
        togglePreview
      } else if control.type == .border {
        borderPreview
      } else if control.type == .matrix {
        matrixPreview
      } else if control.type == .liveMatrix {
        liveMatrixPreview
      } else if control.type == .volumeLevel {
        volumeLevelPreview
      } else if control.type == .matrixInput || control.type == .matrixOutput {
        chipPreview
      } else if control.type == .liveMatrixInput || control.type == .liveMatrixOutput {
        liveMatrixChipEditorPreview
      } else {
        controlPreview
      }

      if isSelected {
        Button(action: onDelete) {
          Image(systemName: "xmark.circle.fill")
            .font(.title3)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .red)
        }
        .padding(4)
      }
    }
  }

  @ViewBuilder
  private var borderPreview: some View {
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

  private var labelPreview: some View {
    let fontSize = Double(control.customFields["fontSize"] ?? "") ?? 18
    let weight = editorFontWeight(control.customFields["fontWeight"] ?? "semibold")
    let alignPair = editorAlignment(control.customFields["textAlign"] ?? "left")
    let color = editorColor(control.customFields["textColor"] ?? "white")
    let iconName = control.customFields["labelIconName"] ?? ""
    let iconSize = CGFloat(Double(control.customFields["labelIconSize"] ?? "") ?? 24)
    let iconPos = control.customFields["labelIconPosition"] ?? "leading"
    let iconColor = editorColor(
      control.customFields["labelIconColor"] ?? (control.customFields["textColor"] ?? "white"))

    let hideText = control.customFields["labelHideText"] == "1"
    let textView = AnyView(Text(control.title)
      .font(.system(size: fontSize, weight: weight))
      .foregroundStyle(color)
      .multilineTextAlignment(alignPair.text)
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
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignPair.frame)
      .padding(10)
      .background(tileColor)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(
            isSelected ? Color.blue : Color.white.opacity(0.15),
            lineWidth: isSelected ? 2.5 : 1
          )
      }
  }

  private var iconPreview: some View {
    let iconOff = control.customFields["iconOff"] ?? "power.circle"
    let iconSize = Double(control.customFields["iconSize"] ?? "") ?? 44
    let colorOff = editorColor(control.customFields["iconColorOff"] ?? "gray")

    return VStack(spacing: 2) {
      Image(systemName: iconOff)
        .font(.system(size: min(iconSize, 36)))
        .foregroundStyle(colorOff)
      if isSelected {
        Text(control.title)
          .font(.caption2)
          .foregroundStyle(.white.opacity(0.7))
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(
          isSelected ? Color.blue : Color.clear,
          lineWidth: isSelected ? 2.5 : 0
        )
    }
  }

  private var matrixPreview: some View {
    let theme = ThemeColors.forTheme(styles.uiTheme)
    let inputCount  = max(1, Int(control.customFields["matrixInputCount"]  ?? "") ?? 4)
    let outputCount = max(1, Int(control.customFields["matrixOutputCount"] ?? "") ?? 4)
    let inputNames  = MatrixNamesHelper.parseNames(control.customFields["matrixInputNames"], count: inputCount, prefix: control.customFields["matrixInputPrefix"] ?? "IN")
    let outputNames = MatrixNamesHelper.parseNames(control.customFields["matrixOutputNames"], count: outputCount, prefix: control.customFields["matrixOutputPrefix"] ?? "OUT")

    let cfChipW: CGFloat     = CGFloat(Double(control.customFields["matrixChipWidth"] ?? "") ?? 80)
    let cfChipH: CGFloat     = CGFloat(Double(control.customFields["matrixChipHeight"] ?? "") ?? 52)
    let chipFontSize: CGFloat = CGFloat(Double(control.customFields["matrixFontSize"] ?? "") ?? 14)
    let chipFontWeight       = matrixPreviewParseFontWeight(control.customFields["matrixFontWeight"] ?? "semibold")
    let titleFontSize: CGFloat = CGFloat(Double(control.customFields["matrixTitleFontSize"] ?? "") ?? 11)
    let titleChipSpacing: CGFloat = CGFloat(Double(control.customFields["matrixTitleChipSpacing"] ?? "") ?? 10)
    let chipSpacing: CGFloat = CGFloat(Double(control.customFields["matrixChipSpacing"] ?? "") ?? 6)
    let sectionSpacing: CGFloat = CGFloat(Double(control.customFields["matrixSectionSpacing"] ?? "") ?? 8)
    let chipLabelFontSize: CGFloat = max(chipFontSize * 1.05, 9)

    let inWidths  = MatrixNamesHelper.parseSizes(control.customFields["matrixInputWidths"], count: inputCount, fallback: cfChipW)
    let inHeights = MatrixNamesHelper.parseSizes(control.customFields["matrixInputHeights"], count: inputCount, fallback: cfChipH)
    let outWidths  = MatrixNamesHelper.parseSizes(control.customFields["matrixOutputWidths"], count: outputCount, fallback: cfChipW)
    let outHeights = MatrixNamesHelper.parseSizes(control.customFields["matrixOutputHeights"], count: outputCount, fallback: cfChipH)

    let inOffX  = MatrixNamesHelper.parseSizes(control.customFields["matrixInputOffsetX"], count: inputCount, fallback: 0)
    let inOffY  = MatrixNamesHelper.parseSizes(control.customFields["matrixInputOffsetY"], count: inputCount, fallback: 0)
    let outOffX = MatrixNamesHelper.parseSizes(control.customFields["matrixOutputOffsetX"], count: outputCount, fallback: 0)
    let outOffY = MatrixNamesHelper.parseSizes(control.customFields["matrixOutputOffsetY"], count: outputCount, fallback: 0)
    let inputAccent = MatrixNamesHelper.parseColor(control.customFields["matrixInputColor"] ?? "blue")
    let outputAccent = MatrixNamesHelper.parseColor(control.customFields["matrixOutputColor"] ?? "green")
    let chipTextColor = MatrixNamesHelper.parseColor(control.customFields["matrixTextColor"] ?? "white")
    let inputBorder = MatrixNamesHelper.matrixBorderColor(
      in: control.customFields, accent: inputAccent, emphasized: false)
    let outputBorder = MatrixNamesHelper.matrixBorderColor(
      in: control.customFields, accent: outputAccent, emphasized: false)

    let tileContentW = max(CGFloat(control.placement.w) * cellW - 6, 24)
    let tileContentH = max(CGFloat(control.placement.h) * cellH - 6, 24)

    let allWidths = inWidths + outWidths
    let totalChipW = allWidths.prefix(max(inputCount, outputCount)).reduce(0, +)
    let n = CGFloat(max(inputCount, outputCount, 1))
    let availW = tileContentW - 16
    let needed = totalChipW + chipSpacing * (n - 1)
    let wScale: CGFloat = needed > availW ? availW / needed : 1.0

    let titleRowH: CGFloat = titleFontSize + 8
    let labelRowH: CGFloat = chipLabelFontSize * 1.4 + 3
    let overhead = 16 + titleRowH * 2 + titleChipSpacing * 2 + sectionSpacing + labelRowH
    let availH = (tileContentH - overhead) / 2
    let maxH = (inHeights + outHeights).max() ?? cfChipH
    let hScale: CGFloat = maxH > availH ? availH / maxH : 1.0

    return VStack(spacing: 0) {
        VStack(alignment: .center, spacing: titleChipSpacing) {
          HStack(spacing: 8) {
            Image(systemName: "display")
              .font(.system(size: max(titleFontSize - 1, 8), weight: .medium))
              .foregroundStyle(theme.iconColor)
            Text(L10n.matrixDisplays)
              .font(.system(size: titleFontSize, weight: .medium))
              .foregroundStyle(theme.textColor.opacity(0.65))
          }
          HStack(alignment: .top, spacing: chipSpacing) {
            Spacer(minLength: 0)
            ForEach(0..<outputCount, id: \.self) { i in
              let ew = outWidths[i] * wScale
              let eh = outHeights[i] * hScale
              let iconSz = max(min(chipFontSize - 4, ew * 0.35), 8)
              VStack(alignment: .center, spacing: 3) {
                VStack(spacing: 2) {
                  Image(systemName: "display")
                    .font(.system(size: iconSz, weight: .medium))
                    .foregroundStyle(chipTextColor.opacity(0.65))
                }
                .padding(.horizontal, max(ew * 0.12, 5))
                .padding(.vertical, max(eh * 0.12, 5))
                .frame(width: ew, height: eh)
                .background(outputAccent.opacity(0.28), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                  RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(outputBorder, lineWidth: 1.5)
                }

                Text(outputNames[i])
                  .font(.system(size: chipLabelFontSize, weight: .medium))
                  .foregroundStyle(chipTextColor.opacity(0.75))
                  .lineLimit(1)
                  .minimumScaleFactor(0.5)
                  .frame(width: ew, height: chipLabelFontSize * 1.4, alignment: .center)
              }
              .offset(x: outOffX[i] * wScale, y: outOffY[i] * hScale)
            }
            Spacer(minLength: 0)
          }
        }
        .frame(maxWidth: .infinity)

        Spacer(minLength: sectionSpacing)

        VStack(alignment: .center, spacing: titleChipSpacing) {
          HStack(spacing: 8) {
            Image(systemName: "video.fill")
              .font(.system(size: max(titleFontSize - 1, 8), weight: .medium))
              .foregroundStyle(theme.iconColor)
            Text(L10n.matrixVideoSources)
              .font(.system(size: titleFontSize, weight: .medium))
              .foregroundStyle(theme.textColor.opacity(0.65))
          }
          HStack(spacing: chipSpacing) {
            Spacer(minLength: 0)
            ForEach(0..<inputCount, id: \.self) { i in
              let ew = inWidths[i] * wScale
              let eh = inHeights[i] * hScale
              let iconSz = max(min(chipFontSize - 4, ew * 0.35), 8)
              let textSz = max(min(chipFontSize * 0.85, ew * 0.3), 8)
              VStack(spacing: 2) {
                Image(systemName: "video.fill")
                  .font(.system(size: iconSz, weight: .medium))
                  .foregroundStyle(chipTextColor)
                Text(inputNames[i])
                  .font(.system(size: textSz, weight: chipFontWeight))
                  .foregroundStyle(chipTextColor)
                  .lineLimit(1)
                  .minimumScaleFactor(0.5)
              }
              .padding(.horizontal, max(ew * 0.12, 5))
              .padding(.vertical, max(eh * 0.12, 5))
              .frame(width: ew, height: eh)
              .background(inputAccent.opacity(0.30), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
              .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                  .stroke(inputBorder, lineWidth: 1.5)
              }
              .offset(x: inOffX[i] * wScale, y: inOffY[i] * hScale)
            }
            Spacer(minLength: 0)
          }
        }
        .frame(maxWidth: .infinity)
      }
      .padding(8)
    .background(tileColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(
          isSelected ? Color.blue : Color.white.opacity(0.15),
          lineWidth: isSelected ? 2.5 : 1
        )
    }
    .shadow(
      color: .black.opacity(0.35),
      radius: styles.shadowBlur,
      x: 0, y: styles.shadowY
    )
  }

  private func matrixPreviewParseFontWeight(_ raw: String) -> Font.Weight {
    switch raw.lowercased() {
    case "ultralight": return .ultraLight
    case "thin": return .thin
    case "light": return .light
    case "regular": return .regular
    case "medium": return .medium
    case "semibold": return .semibold
    case "bold": return .bold
    case "heavy": return .heavy
    case "black": return .black
    default: return .semibold
    }
  }

  private var liveMatrixPreview: some View {
    let theme = ThemeColors.forTheme(styles.uiTheme)
    let inputCount  = max(1, Int(control.customFields["liveMatrixInputCount"]  ?? "") ?? 4)
    let outputCount = max(1, Int(control.customFields["liveMatrixOutputCount"] ?? "") ?? 4)
    let inputNames  = MatrixNamesHelper.parseNames(control.customFields["liveMatrixInputNames"], count: inputCount, prefix: control.customFields["liveMatrixInputPrefix"] ?? "Tx")
    let outputNames = MatrixNamesHelper.parseNames(control.customFields["liveMatrixOutputNames"], count: outputCount, prefix: control.customFields["liveMatrixOutputPrefix"] ?? "Rx")
    let isVertical = (control.customFields["liveMatrixLayout"] ?? "horizontal") == "vertical"

    let cfChipW: CGFloat = CGFloat(Double(control.customFields["liveMatrixChipWidth"] ?? "") ?? 160)
    let cfChipH: CGFloat = CGFloat(Double(control.customFields["liveMatrixChipHeight"] ?? "") ?? 120)
    let cfOutW: CGFloat  = CGFloat(Double(control.customFields["liveMatrixOutputChipWidth"] ?? "") ?? Double(cfChipW))
    let cfOutH: CGFloat  = CGFloat(Double(control.customFields["liveMatrixOutputChipHeight"] ?? "") ?? Double(cfChipH))
    let chipFontSize: CGFloat = CGFloat(Double(control.customFields["liveMatrixFontSize"] ?? "") ?? 12)
    let chipFontWeight       = matrixPreviewParseFontWeight(control.customFields["liveMatrixFontWeight"] ?? "semibold")
    let titleFontSize: CGFloat = CGFloat(Double(control.customFields["liveMatrixTitleFontSize"] ?? "") ?? 12)
    let chipSpacing: CGFloat = CGFloat(Double(control.customFields["liveMatrixChipSpacing"] ?? "") ?? 8)
    let titleChipSpacing: CGFloat = CGFloat(Double(control.customFields["liveMatrixTitleChipSpacing"] ?? "") ?? 8)

    let inWidths  = MatrixNamesHelper.parseSizes(control.customFields["liveMatrixInputWidths"], count: inputCount, fallback: cfChipW)
    let inHeights = MatrixNamesHelper.parseSizes(control.customFields["liveMatrixInputHeights"], count: inputCount, fallback: cfChipH)
    let outWidths  = MatrixNamesHelper.parseSizes(control.customFields["liveMatrixOutputWidths"], count: outputCount, fallback: cfOutW)
    let outHeights = MatrixNamesHelper.parseSizes(control.customFields["liveMatrixOutputHeights"], count: outputCount, fallback: cfOutH)

    let inOffX  = MatrixNamesHelper.parseSizes(control.customFields["liveMatrixInputOffsetX"], count: inputCount, fallback: 0)
    let inOffY  = MatrixNamesHelper.parseSizes(control.customFields["liveMatrixInputOffsetY"], count: inputCount, fallback: 0)
    let outOffX = MatrixNamesHelper.parseSizes(control.customFields["liveMatrixOutputOffsetX"], count: outputCount, fallback: 0)
    let outOffY = MatrixNamesHelper.parseSizes(control.customFields["liveMatrixOutputOffsetY"], count: outputCount, fallback: 0)

    let tileContentW = max(CGFloat(control.placement.w) * cellW - 6, 24)
    let tileContentH = max(CGFloat(control.placement.h) * cellH - 6, 24)
    let sc = self.lmPreviewFittedScale(
      in: CGSize(width: tileContentW, height: tileContentH),
      inWidths: inWidths, inHeights: inHeights,
      outWidths: outWidths, outHeights: outHeights,
      titleFontSize: titleFontSize, titleChipSpacing: titleChipSpacing,
      chipSpacing: chipSpacing, inputCount: inputCount, outputCount: outputCount,
      isVertical: isVertical
    )

    return Group {
      if isVertical {
        VStack(spacing: 0) {
          self.lmPreviewPerChipSection(
            icon: "display", title: L10n.liveMatrixDisplays,
            count: outputCount, names: outputNames,
            widths: outWidths, heights: outHeights,
            offsetsX: outOffX, offsetsY: outOffY,
            xKey: "liveMatrixOutputOffsetX", yKey: "liveMatrixOutputOffsetY",
            scale: sc,
            chipFontSize: chipFontSize, chipFontWeight: chipFontWeight,
            titleFontSize: titleFontSize, chipSpacing: chipSpacing,
            titleChipSpacing: titleChipSpacing, theme: theme,
            isScrollHorizontal: true,
            chipRole: "liveMatrixOutput"
          )
          Spacer(minLength: 4)
          self.lmPreviewPerChipSection(
            icon: "video.fill", title: L10n.liveMatrixSources,
            count: inputCount, names: inputNames,
            widths: inWidths, heights: inHeights,
            offsetsX: inOffX, offsetsY: inOffY,
            xKey: "liveMatrixInputOffsetX", yKey: "liveMatrixInputOffsetY",
            scale: sc,
            chipFontSize: chipFontSize, chipFontWeight: chipFontWeight,
            titleFontSize: titleFontSize, chipSpacing: chipSpacing,
            titleChipSpacing: titleChipSpacing, theme: theme,
            isScrollHorizontal: true,
            chipRole: "liveMatrixInput"
          )
        }
        .padding(8)
      } else {
        HStack(alignment: .top, spacing: 0) {
          let maxInW = (inWidths.max() ?? cfChipW) * sc.w
          let maxOutW = (outWidths.max() ?? cfOutW) * sc.w
          self.lmPreviewPerChipSection(
            icon: "video.fill", title: L10n.liveMatrixSources,
            count: inputCount, names: inputNames,
            widths: inWidths, heights: inHeights,
            offsetsX: inOffX, offsetsY: inOffY,
            xKey: "liveMatrixInputOffsetX", yKey: "liveMatrixInputOffsetY",
            scale: sc,
            chipFontSize: chipFontSize, chipFontWeight: chipFontWeight,
            titleFontSize: titleFontSize, chipSpacing: chipSpacing,
            titleChipSpacing: titleChipSpacing, theme: theme,
            isScrollHorizontal: false,
            chipRole: "liveMatrixInput"
          )
          .frame(width: maxInW, alignment: .center)
          Spacer(minLength: 4)
          self.lmPreviewPerChipSection(
            icon: "display", title: L10n.liveMatrixDisplays,
            count: outputCount, names: outputNames,
            widths: outWidths, heights: outHeights,
            offsetsX: outOffX, offsetsY: outOffY,
            xKey: "liveMatrixOutputOffsetX", yKey: "liveMatrixOutputOffsetY",
            scale: sc,
            chipFontSize: chipFontSize, chipFontWeight: chipFontWeight,
            titleFontSize: titleFontSize, chipSpacing: chipSpacing,
            titleChipSpacing: titleChipSpacing, theme: theme,
            isScrollHorizontal: false,
            chipRole: "liveMatrixOutput"
          )
          .frame(width: maxOutW, alignment: .center)
        }
        .padding(8)
      }
    }
    .frame(width: tileContentW, height: tileContentH)
    .background(theme.idleButtonBg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(
          isSelected ? Color.blue : theme.idleBorder,
          lineWidth: isSelected ? 2.5 : 1
        )
    }
    .shadow(
      color: .black.opacity(0.35),
      radius: styles.shadowBlur,
      x: 0, y: styles.shadowY
    )
  }

  private struct LMPreviewScale { var w: CGFloat; var h: CGFloat }

  private func lmPreviewFittedScale(
    in totalSize: CGSize, inWidths: [CGFloat], inHeights: [CGFloat],
    outWidths: [CGFloat], outHeights: [CGFloat],
    titleFontSize: CGFloat, titleChipSpacing: CGFloat, chipSpacing: CGFloat,
    inputCount: Int, outputCount: Int, isVertical: Bool
  ) -> LMPreviewScale {
    let titleRowH = titleFontSize + 8
    let n = CGFloat(max(inputCount, outputCount, 1))

    if isVertical {
      let availableW = max(totalSize.width - 16, 60)
      let maxInW = inWidths.max() ?? 40
      let maxOutW = outWidths.max() ?? 40
      let maxW = max(maxInW, maxOutW)
      let wScale: CGFloat = maxW > availableW ? availableW / maxW : 1.0

      let halfRow = (totalSize.height - 16 - (titleRowH + titleChipSpacing) * 2 - 4) / 2
      let scrollH = max(halfRow - titleRowH - titleChipSpacing, 40)
      let maxInH = inHeights.max() ?? 20
      let maxOutH = outHeights.max() ?? 20
      let maxH = max(maxInH, maxOutH)
      let hScale: CGFloat = maxH > scrollH ? scrollH / maxH : 1.0

      return LMPreviewScale(w: max(wScale, 0.2), h: max(hScale, 0.2))
    }

    let availableH = totalSize.height - 16 - titleRowH - titleChipSpacing
    let maxPerChipH = (availableH - chipSpacing * (n - 1)) / n
    let maxH = max(inHeights.max() ?? 20, outHeights.max() ?? 20)
    let hScale: CGFloat = maxH > maxPerChipH ? maxPerChipH / maxH : 1.0

    let gapBetween: CGFloat = 4
    let innerArea = max(totalSize.width - 16, 120)
    let maxInW = inWidths.max() ?? 40
    let maxOutW = outWidths.max() ?? 40
    let pairSum = maxInW + maxOutW
    let wScale: CGFloat = pairSum > 0 ? min(1, (innerArea - gapBetween) / pairSum) : 1

    return LMPreviewScale(w: max(wScale, 0.2), h: max(hScale, 0.2))
  }

  private func lmPreviewPerChipSection(
    icon: String, title: String,
    count: Int, names: [String],
    widths: [CGFloat], heights: [CGFloat],
    offsetsX: [CGFloat], offsetsY: [CGFloat],
    xKey: String, yKey: String,
    scale: LMPreviewScale,
    chipFontSize: CGFloat, chipFontWeight: Font.Weight,
    titleFontSize: CGFloat, chipSpacing: CGFloat,
    titleChipSpacing: CGFloat, theme: ThemeColors,
    isScrollHorizontal: Bool,
    chipRole: String = ""
  ) -> some View {
    VStack(alignment: .center, spacing: titleChipSpacing) {
      HStack(spacing: 6) {
        Image(systemName: icon)
          .font(.system(size: max(titleFontSize - 1, 8), weight: .medium))
          .foregroundStyle(theme.iconColor)
        Text(title)
          .font(.system(size: titleFontSize, weight: .medium))
          .foregroundStyle(theme.textColor.opacity(0.65))
      }
      if isScrollHorizontal {
        HStack(spacing: chipSpacing) {
          ForEach(0..<count, id: \.self) { i in
            self.lmPreviewChip(
              name: names[i], icon: icon,
              cw: widths[i] * scale.w, ch: heights[i] * scale.h,
              chipFontSize: chipFontSize, chipFontWeight: chipFontWeight,
              theme: theme
            )
            .offset(x: offsetsX[i] * scale.w, y: offsetsY[i] * scale.h)
          }
        }
        .frame(maxWidth: .infinity, alignment: .center)
      } else {
        VStack(spacing: chipSpacing) {
          ForEach(0..<count, id: \.self) { i in
            self.lmPreviewChip(
              name: names[i], icon: icon,
              cw: widths[i] * scale.w, ch: heights[i] * scale.h,
              chipFontSize: chipFontSize, chipFontWeight: chipFontWeight,
              theme: theme
            )
            .offset(x: offsetsX[i] * scale.w, y: offsetsY[i] * scale.h)
          }
        }
        .frame(maxWidth: .infinity, alignment: .center)
      }
    }
  }

  private func lmPreviewChip(
    name: String, icon: String,
    cw: CGFloat, ch: CGFloat,
    chipFontSize: CGFloat, chipFontWeight: Font.Weight,
    theme: ThemeColors
  ) -> some View {
    let textSz = max(min(chipFontSize, cw * 0.12), 8)
    return ZStack(alignment: .bottomLeading) {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(theme.idleButtonBg)
      Image(systemName: icon)
        .font(.system(size: max(min(cw * 0.18, ch * 0.25), 8), weight: .medium))
        .foregroundStyle(theme.textColor.opacity(0.3))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Text(name)
        .font(.system(size: textSz, weight: chipFontWeight))
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .padding(4)
    }
    .frame(width: cw, height: ch)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(theme.idleBorder, lineWidth: 1.5)
    }
    .shadow(color: .black.opacity(0.35), radius: styles.shadowBlur, x: 0, y: styles.shadowY)
  }

  private var volumeLevelPreview: some View {
    let count = max(2, min(Int(control.customFields["volumeLevelCount"] ?? "") ?? 8, 16))
    let activeColor = editorColor(control.customFields["volumeActiveColor"] ?? "green")
    let inactiveColor = editorColor(control.customFields["volumeInactiveColor"] ?? "gray")
    let pos = control.customFields["volumeDefaultPosition"] ?? "center"
    let titlePos = control.customFields["volumeTitlePosition"] ?? "top"
    let showTitle = titlePos != "hidden" && !control.title.isEmpty
    let demoLevel: Int = {
      switch pos {
      case "top": return count - 1
      case "bottom": return 0
      default: return (count - 1) / 2
      }
    }()

    let titleLabel = Text(control.title)
      .font(.system(size: 9, weight: .medium))
      .foregroundStyle(.white.opacity(0.55))
      .lineLimit(1)
      .minimumScaleFactor(0.5)
      .frame(maxWidth: .infinity, alignment: .center)

    return VStack(spacing: 3) {
      if showTitle && titlePos == "top" { titleLabel }

      GeometryReader { geo in
        let h = geo.size.height
        let pvTrackW: CGFloat = 3
        let pvNotchW: CGFloat = 10
        let pvThumbW: CGFloat = 20
        let pvThumbH: CGFloat = 7
        let topPad = pvThumbH / 2
        let usable = h - pvThumbH
        let sliderX: CGFloat = geo.size.width / 2

        ZStack {
          RoundedRectangle(cornerRadius: pvTrackW / 2)
            .fill(inactiveColor.opacity(0.2))
            .frame(width: pvTrackW, height: h)
            .position(x: sliderX, y: h / 2)

          // Faint notches in preview (since no drag in editor)
          ForEach(0..<count, id: \.self) { i in
            let frac = CGFloat(i) / CGFloat(max(count - 1, 1))
            let y = topPad + usable * (1.0 - frac)
            Rectangle()
              .fill(.white.opacity(0.1))
              .frame(width: pvNotchW, height: 0.5)
              .position(x: sliderX, y: y)
          }

          let thumbY = topPad + usable * (1.0 - CGFloat(demoLevel) / CGFloat(max(count - 1, 1)))
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(activeColor)
            .frame(width: pvThumbW, height: pvThumbH)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .position(x: sliderX, y: thumbY)
        }
        .frame(width: geo.size.width, height: h)
      }

      if showTitle && titlePos == "bottom" { titleLabel }
    }
    .padding(6)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(tileColor)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(
          isSelected ? Color.blue : Color.white.opacity(0.15),
          lineWidth: isSelected ? 2.5 : 1
        )
    }
    .shadow(
      color: .black.opacity(0.25),
      radius: styles.shadowBlur * 0.5,
      x: 0, y: styles.shadowY * 0.6
    )
  }

  private var chipPreview: some View {
    let chipName = control.customFields["chipName"] ?? control.title
    let parentTitle = control.customFields["parentTitle"] ?? ""
    let isInput = control.type == .matrixInput
    let icon = isInput ? "video.fill" : "display"
    let cw = max(CGFloat(control.placement.w) * cellW - 6, 24)
    let ch = max(CGFloat(control.placement.h) * cellH - 6, 24)
    let textSz = max(min(12.0, cw * 0.12), 8)
    let parentSz = max(min(9.0, cw * 0.09), 7)
    let parent: ControlItem? = {
      guard let pid = UUID(uuidString: control.customFields["parentControlID"] ?? "") else { return nil }
      return modelStore.draft.controls.first { $0.id == pid }
    }()
    let colorKey = isInput ? "matrixInputColor" : "matrixOutputColor"
    let accent = MatrixNamesHelper.parseColor(parent?.customFields[colorKey] ?? (isInput ? "blue" : "green"))
    let labelColor = MatrixNamesHelper.parseColor(parent?.customFields["matrixTextColor"] ?? "white")
    let chipBorder = MatrixNamesHelper.matrixBorderColor(
      in: parent?.customFields ?? [:], accent: accent, emphasized: false)

    return ZStack(alignment: .bottomLeading) {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(accent.opacity(0.30))
      Image(systemName: icon)
        .font(.system(size: max(min(cw * 0.18, ch * 0.25), 8), weight: .medium))
        .foregroundStyle(labelColor.opacity(0.35))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Text(chipName)
        .font(.system(size: textSz, weight: .semibold))
        .foregroundStyle(labelColor)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .padding(4)
    }
    .frame(width: cw, height: ch)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(
          isSelected ? Color.blue : chipBorder,
          lineWidth: isSelected ? 2.5 : 1.5
        )
    }
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
    .shadow(color: .black.opacity(0.35), radius: styles.shadowBlur, x: 0, y: styles.shadowY)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// Decomposed live-matrix chip — matches runtime (MJPEG area + label) instead of the static icon tile.
  private var liveMatrixChipEditorPreview: some View {
    let theme = ThemeColors.forTheme(styles.uiTheme)
    let chipName = control.customFields["chipName"] ?? control.title
    let parentTitle = control.customFields["parentTitle"] ?? ""
    let isInput = control.type == .liveMatrixInput
    let parent: ControlItem? = {
      guard let pid = UUID(uuidString: control.customFields["parentControlID"] ?? "") else { return nil }
      return modelStore.draft.controls.first { $0.id == pid }
    }()
    let fontS = CGFloat(Double(parent?.customFields["liveMatrixFontSize"] ?? "") ?? 12)
    let fontW = matrixPreviewParseFontWeight(parent?.customFields["liveMatrixFontWeight"] ?? "semibold")
    let cw = max(CGFloat(control.placement.w) * cellW - 6, 24)
    let ch = max(CGFloat(control.placement.h) * cellH - 6, 24)
    let textSz = max(min(fontS, cw * 0.12), 8)
    let srcTextSz = max(min(fontS * 0.75, cw * 0.10), 7)
    let hintSz = max(min(9.0, cw * 0.07), 6)
    let parentSz = max(min(9.0, cw * 0.09), 7)
    let sampleSourceName: String = {
      guard let p = parent else { return "Tx1" }
      let c = max(1, Int(p.customFields["liveMatrixInputCount"] ?? "") ?? 4)
      let arr = MatrixNamesHelper.parseNames(
        p.customFields["liveMatrixInputNames"], count: c,
        prefix: p.customFields["liveMatrixInputPrefix"] ?? "Tx")
      return arr.first ?? "Tx1"
    }()

    let cardBg = theme.idleButtonBg
    let borderCol = isSelected ? Color.blue : theme.idleBorder
    let borderLine: CGFloat = isSelected ? 2.5 : 1.5

    return VStack(spacing: 3) {
      ZStack(alignment: isInput ? .bottomLeading : .bottom) {
        ZStack {
          Color.black
          Text("Stream")
            .font(.system(size: hintSz, weight: .medium))
            .foregroundStyle(Color(white: 0.35))
        }
        .frame(width: cw, height: ch)
        Group {
          if isInput {
            Text(chipName)
              .font(.system(size: textSz, weight: fontW))
              .foregroundStyle(.white)
              .lineLimit(1)
              .minimumScaleFactor(0.5)
          } else {
            HStack(spacing: 4) {
              Text(chipName)
                .font(.system(size: textSz, weight: fontW))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
              Text("← \(sampleSourceName)")
                .font(.system(size: srcTextSz, weight: .medium))
                .foregroundStyle(theme.activeBorder)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            }
          }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .padding(4)
      }
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .background(cardBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .shadow(color: .black.opacity(0.35), radius: styles.shadowBlur, x: 0, y: styles.shadowY)
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
          .stroke(borderCol, lineWidth: borderLine)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var togglePreview: some View {
    let fontSize = Double(control.customFields["fontSize"] ?? "") ?? 15
    let weight = editorFontWeight(control.customFields["fontWeight"] ?? "semibold")
    let textColor = editorColor(control.customFields["textColor"] ?? "white")

    return HStack(spacing: 8) {
      Text(control.title)
        .font(.system(size: fontSize, weight: weight))
        .foregroundStyle(textColor)
        .lineLimit(2)
        .minimumScaleFactor(0.5)

      Spacer()

      ZStack {
        Capsule()
          .fill(Color.gray.opacity(0.5))
          .frame(width: 36, height: 20)
        Circle()
          .fill(.white)
          .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
          .frame(width: 16, height: 16)
          .offset(x: -8)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(tileColor)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(
          isSelected ? Color.blue : Color.white.opacity(0.15),
          lineWidth: isSelected ? 2.5 : 1
        )
    }
    .shadow(
      color: .black.opacity(0.25),
      radius: styles.shadowBlur * 0.5,
      x: 0, y: styles.shadowY * 0.6
    )
  }

  private var controlPreview: some View {
    let fontSize = Double(control.customFields["fontSize"] ?? "") ?? 17
    let weight = editorFontWeight(control.customFields["fontWeight"] ?? "semibold")
    let color = editorColor(control.customFields["textColor"] ?? "white")

    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 4) {
        Image(systemName: typeIcon)
          .font(.caption2)
          .foregroundStyle(.white.opacity(0.7))
        Text(control.type.rawValue.uppercased())
          .font(.caption2)
          .foregroundStyle(.white.opacity(0.7))
        Spacer()
      }

      Text(control.title)
        .font(.system(size: fontSize, weight: weight))
        .foregroundStyle(color)
        .lineLimit(2)
        .minimumScaleFactor(0.5)

      Text(behaviorLabel)
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.55))

      if isSelected {
        Text(fmtPlacement(control.placement.w) + "×" + fmtPlacement(control.placement.h))
          .font(.caption2.monospacedDigit().weight(.semibold))
          .foregroundStyle(.cyan.opacity(0.85))
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(tileColor)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(
          isSelected ? Color.blue : Color.white.opacity(0.15),
          lineWidth: isSelected ? 2.5 : 1
        )
    }
    .shadow(
      color: .black.opacity(0.25),
      radius: styles.shadowBlur * 0.5,
      x: 0, y: styles.shadowY * 0.6
    )
  }

  private var tileColor: Color {
    switch control.type {
    case .button: return .black.opacity(0.52)
    case .slider: return .indigo.opacity(0.55)
    case .toggle: return .teal.opacity(0.5)
    case .label: return .gray.opacity(0.25)
    case .icon: return .clear
    case .border: return .clear
    case .matrix: return Color(red: 0.07, green: 0.09, blue: 0.17).opacity(0.88)
    case .liveMatrix: return Color(red: 0.05, green: 0.10, blue: 0.18).opacity(0.90)
    case .volumeLevel: return Color(red: 0.08, green: 0.14, blue: 0.08).opacity(0.85)
    case .matrixInput, .matrixOutput: return Color(red: 0.07, green: 0.09, blue: 0.17).opacity(0.88)
    case .liveMatrixInput, .liveMatrixOutput: return Color(red: 0.05, green: 0.10, blue: 0.18).opacity(0.90)
    }
  }

  private var typeIcon: String {
    switch control.type {
    case .button: return "hand.tap"
    case .slider: return "slider.horizontal.3"
    case .toggle: return "switch.2"
    case .label: return "textformat"
    case .icon: return "power.circle"
    case .border: return "rectangle"
    case .matrix: return "rectangle.split.2x2"
    case .liveMatrix: return "video.badge.waveform"
    case .volumeLevel: return "slider.vertical.3"
    case .matrixInput: return "video.fill"
    case .matrixOutput: return "display"
    case .liveMatrixInput: return "video.fill"
    case .liveMatrixOutput: return "display"
    }
  }

  private var behaviorLabel: String {
    switch control.behavior {
    case .momentary: return "Momentary"
    case .toggle: return "Toggle"
    case .radio:
      if let key = control.groupKey, !key.isEmpty {
        return "Radio: \(key)"
      }
      return "Radio"
    }
  }

  private func editorFontWeight(_ value: String) -> Font.Weight {
    switch value {
    case "regular": return .regular
    case "medium": return .medium
    case "bold": return .bold
    default: return .semibold
    }
  }

  private func editorAlignment(_ value: String) -> (text: TextAlignment, frame: Alignment) {
    switch value {
    case "center": return (.center, .center)
    case "right": return (.trailing, .trailing)
    default: return (.leading, .leading)
    }
  }

  private func editorColor(_ value: String) -> Color {
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

// MARK: - Color Hex Utilities

extension Color {
  init(hexString: String) {
    var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
    if hex.hasPrefix("#") { hex.removeFirst() }
    var rgb: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&rgb)
    let r = Double((rgb >> 16) & 0xFF) / 255
    let g = Double((rgb >> 8) & 0xFF) / 255
    let b = Double(rgb & 0xFF) / 255
    self.init(red: r, green: g, blue: b)
  }

  func toHexString() -> String {
    let uiColor = UIColor(self)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
    uiColor.getRed(&r, green: &g, blue: &b, alpha: nil)
    return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
  }
}

/// Compute gradient start/end UnitPoints from an angle in degrees (0° = left→right, 90° = top→bottom).
func borderGradientPoints(_ angleDeg: Double) -> (UnitPoint, UnitPoint) {
  let rad = angleDeg * .pi / 180
  let cx = cos(rad) * 0.5, cy = sin(rad) * 0.5
  return (UnitPoint(x: 0.5 - cx, y: 0.5 - cy), UnitPoint(x: 0.5 + cx, y: 0.5 + cy))
}

// MARK: - Draggable Logo

private struct DraggableLogo: View {
  let image: Image
  @Binding var logoW: Double
  @Binding var logoH: Double
  @Binding var logoX: Double
  @Binding var logoY: Double
  let canvasWidth: CGFloat
  let canvasHeight: CGFloat

  @State private var dragOffset: CGSize = .zero
  @State private var isDragging = false
  @State private var resizeOffset: CGSize = .zero
  @State private var isResizing = false

  private var currentW: CGFloat { max(40, logoW + (isResizing ? resizeOffset.width : 0)) }
  private var currentH: CGFloat { max(20, logoH + (isResizing ? resizeOffset.height : 0)) }

  var body: some View {
    let centerX = logoX + currentW / 2 + (isDragging ? dragOffset.width : 0)
    let centerY = logoY + currentH / 2 + (isDragging ? dragOffset.height : 0)

    ZStack(alignment: .bottomTrailing) {
      image
        .resizable()
        .scaledToFit()
        .frame(width: currentW, height: currentH)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(Color.cyan, lineWidth: (isDragging || isResizing) ? 2.5 : 1.5)
        }
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)

      Image(systemName: "arrow.down.right.and.arrow.up.left")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: 22, height: 22)
        .background(Color.cyan, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .padding(2)
        .highPriorityGesture(
          DragGesture(minimumDistance: 3)
            .onChanged { value in
              isResizing = true
              resizeOffset = value.translation
            }
            .onEnded { value in
              isResizing = false
              logoW = max(40, min(400, logoW + value.translation.width))
              logoH = max(20, min(200, logoH + value.translation.height))
              resizeOffset = .zero
            }
        )
    }
    .frame(width: currentW, height: currentH)
    .position(x: centerX, y: centerY)
    .opacity(isDragging ? 0.8 : 1.0)
    .zIndex(200)
    .gesture(
      DragGesture(minimumDistance: 3)
        .onChanged { value in
          guard !isResizing else { return }
          isDragging = true
          dragOffset = value.translation
        }
        .onEnded { value in
          guard !isResizing else { return }
          isDragging = false
          logoX = max(0, min(canvasWidth - logoW, logoX + value.translation.width))
          logoY = max(0, min(canvasHeight - logoH, logoY + value.translation.height))
          dragOffset = .zero
        }
    )
  }
}

// MARK: - Control Property Sheet (with inline command editor)

struct ControlPropertySheet: View {
  @EnvironmentObject private var modelStore: UnifiedModelStore
  @EnvironmentObject private var transport: TcpTransport
  @Environment(\.dismiss) private var dismiss

  @State private var control: ControlItem
  @State private var commandName: String = ""
  @State private var commandPayloadKind: PayloadKind = .text
  @State private var commandPayload: String = ""
  @State private var commandLineEnding: LineEnding = .crlf
  @State private var commandTimeoutMs: Int = 1500
  @State private var boundCommandID: UUID?
  /// Collapsible "input / output columns" for matrix and liveMatrix property sheets
  @State private var matrixIOColumnsExpanded: Bool = false
  /// Tracks which per-device rows are currently fetching info ("in_0", "out_1", …)
  @State private var fetchingInfo: Set<String> = []
  /// Per-row fetch error messages keyed by "in_0" / "out_1"
  @State private var fetchError: [String: String] = [:]
  @State private var streamPreviewExpanded: Set<Int> = []
  @State private var fetchingAllInputs = false
  @State private var channelCountNotice: String?
  @State private var discoveredEncoders: [MatrixDiscoveredDevice] = []
  @State private var discoveredDecoders: [MatrixDiscoveredDevice] = []
  @State private var fetchingDeviceList = false
  @State private var deviceListError: String?

  private let onCommit: (ControlItem, CommandItem?) -> Void
  /// When set, toolbar offers a menu to jump to another control (commits current edits first).
  private let onSelectOther: ((UUID) -> Void)?

  init(
    control: ControlItem,
    onCommit: @escaping (ControlItem, CommandItem?) -> Void,
    onSelectOther: ((UUID) -> Void)? = nil
  ) {
    self._control = State(initialValue: control)
    self.onCommit = onCommit
    self.onSelectOther = onSelectOther
  }

  var body: some View {
    NavigationStack {
      Form {
        basicInfoSection
        if control.type == .matrix {
          matrixConfigSection
        } else if control.type == .liveMatrix {
          liveMatrixConfigSection
        } else if control.type == .volumeLevel {
          volumeLevelConfigSection
        } else if control.type == .matrixInput || control.type == .matrixOutput
                    || control.type == .liveMatrixInput || control.type == .liveMatrixOutput {
          chipBasicSection
          chipCommandOverrideSection
          if control.type == .liveMatrixInput {
            chipInputStreamSection
          }
          if control.type == .liveMatrixOutput {
            chipOutputPreviewSection
          }
          if control.type == .matrixOutput || control.type == .liveMatrixOutput {
            chipRouteRestrictionSection
          }
        } else if control.type == .icon {
          iconStyleSection
        } else if control.type == .border {
          borderStyleSection
        } else {
          textStyleSection
        }
        if control.type != .label && control.type != .icon && control.type != .toggle
            && control.type != .border
            && control.type != .matrix && control.type != .liveMatrix && control.type != .volumeLevel
            && control.type != .matrixInput && control.type != .matrixOutput
            && control.type != .liveMatrixInput && control.type != .liveMatrixOutput {
          behaviorSection
        }
        gridPositionSection
        if control.type == .matrix || control.type == .liveMatrix {
          deviceSection
        } else if control.type == .matrixInput || control.type == .matrixOutput
                    || control.type == .liveMatrixInput || control.type == .liveMatrixOutput {
          chipInheritedDeviceSection
        } else if control.type == .volumeLevel {
          deviceSection
        } else if control.type != .label && control.type != .border {
          deviceSection
          commandSection
          if control.type == .icon || control.type == .toggle {
            offCommandSection
            toggleMultiCommandSection
          }
          if control.type == .button {
            multiCommandSection
          }
        }
        customFieldsSection
      }
      .navigationTitle("Control Properties")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if onSelectOther != nil {
          ToolbarItem(placement: .topBarLeading) {
            Menu {
              ForEach(modelStore.draft.controls) { c in
                Button {
                  switchToElement(c.id)
                } label: {
                  HStack {
                    Text(c.title)
                      .lineLimit(1)
                    if c.id == control.id {
                      Spacer(minLength: 8)
                      Image(systemName: "checkmark")
                    }
                  }
                }
              }
            } label: {
              Label("Switch", systemImage: "arrow.left.arrow.right.circle")
            }
            .accessibilityLabel("Switch element")
          }
        }
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { saveAll() }
            .fontWeight(.semibold)
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .onAppear { loadBoundCommand() }
  }

  // MARK: Sections

  private var basicInfoSection: some View {
    Section("Basic Info") {
      LabeledContent("Type") {
        typeTag
      }
      TextField("Label", text: $control.title)
      if (control.type == .matrix || control.type == .liveMatrix)
          && control.isExplodedMatrixParentHiddenFromCanvas {
        Text("Decomposed: this control is hidden on the page; it only provides configuration and routing for the chip controls.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var textStyleSection: some View {
    Group {
      labelIconSection
      Section("Text Style") {
      Stepper(
        "Font Size: \(Int(textFontSize))",
        value: Binding(
          get: { textFontSize },
          set: { control.customFields["fontSize"] = String(Int($0)) }
        ),
        in: 10...72, step: 2
      )

      Picker("Alignment", selection: Binding(
        get: { control.customFields["textAlign"] ?? "left" },
        set: { control.customFields["textAlign"] = $0 }
      )) {
        Label("Left", systemImage: "text.alignleft").tag("left")
        Label("Center", systemImage: "text.aligncenter").tag("center")
        Label("Right", systemImage: "text.alignright").tag("right")
      }
      .pickerStyle(.segmented)

      Picker("Font Weight", selection: Binding(
        get: { control.customFields["fontWeight"] ?? "semibold" },
        set: { control.customFields["fontWeight"] = $0 }
      )) {
        Text("Regular").tag("regular")
        Text("Medium").tag("medium")
        Text("Semibold").tag("semibold")
        Text("Bold").tag("bold")
      }

      Picker("Text Color", selection: Binding(
        get: { control.customFields["textColor"] ?? "white" },
        set: { control.customFields["textColor"] = $0 }
      )) {
        Text("White").tag("white")
        Text("Black").tag("black")
        Text("Gray").tag("gray")
        Text("Blue").tag("blue")
        Text("Green").tag("green")
        Text("Orange").tag("orange")
        Text("Red").tag("red")
        Text("Cyan").tag("cyan")
        Text("Yellow").tag("yellow")
      }
    }
    }
  }

  private var labelIconSection: some View {
    let hasIcon = !(control.customFields["labelIconName"] ?? "").isEmpty
    return Section("Icon") {
      Toggle("显示图标", isOn: Binding(
        get: { hasIcon },
        set: { on in
          control.customFields["labelIconName"] = on ? "star.circle" : ""
        }
      ))

      if hasIcon {
        IconGridPicker(
          title: "图标",
          selection: Binding(
            get: { control.customFields["labelIconName"] ?? "star.circle" },
            set: { control.customFields["labelIconName"] = $0 }
          ),
          categories: iconCategories
        )

        Stepper(
          "图标大小: \(Int(Double(control.customFields["labelIconSize"] ?? "") ?? 24))",
          value: Binding(
            get: { Double(control.customFields["labelIconSize"] ?? "") ?? 24 },
            set: { control.customFields["labelIconSize"] = String(Int($0)) }
          ),
          in: 12...80, step: 2
        )

        Picker("位置", selection: Binding(
          get: { control.customFields["labelIconPosition"] ?? "leading" },
          set: { control.customFields["labelIconPosition"] = $0 }
        )) {
          Label("左", systemImage: "arrow.left").tag("leading")
          Label("右", systemImage: "arrow.right").tag("trailing")
          Label("上", systemImage: "arrow.up").tag("top")
          Label("下", systemImage: "arrow.down").tag("bottom")
        }
        .pickerStyle(.segmented)

        Picker("图标颜色", selection: Binding(
          get: { control.customFields["labelIconColor"] ?? (control.customFields["textColor"] ?? "white") },
          set: { control.customFields["labelIconColor"] = $0 }
        )) {
          Text("White").tag("white")
          Text("Black").tag("black")
          Text("Gray").tag("gray")
          Text("Blue").tag("blue")
          Text("Green").tag("green")
          Text("Orange").tag("orange")
          Text("Red").tag("red")
          Text("Cyan").tag("cyan")
          Text("Yellow").tag("yellow")
        }

        Toggle("隐藏文字（纯图标）", isOn: Binding(
          get: { control.customFields["labelHideText"] == "1" },
          set: { control.customFields["labelHideText"] = $0 ? "1" : "0" }
        ))
      }
    }
  }

  private var textFontSize: Double {
    Double(control.customFields["fontSize"] ?? "") ?? 17
  }

  // MARK: Level Config

  private var volumeLevelConfigSection: some View {
    Group {
      volumeLevelBasicSection
      volumeLevelPerLevelSection
      volumeLevelStyleSection
    }
  }

  private var volumeLevelBasicSection: some View {
    Section("Levels") {
      Stepper(
        "Level Count: \(Int(control.customFields["volumeLevelCount"] ?? "") ?? 8)",
        value: Binding(
          get: { Double(Int(control.customFields["volumeLevelCount"] ?? "") ?? 8) },
          set: { control.customFields["volumeLevelCount"] = String(Int($0)) }
        ),
        in: 2...20, step: 1
      )

      Picker("Default Position", selection: Binding(
        get: { control.customFields["volumeDefaultPosition"] ?? "center" },
        set: { control.customFields["volumeDefaultPosition"] = $0 }
      )) {
        Text("Bottom").tag("bottom")
        Text("Center").tag("center")
        Text("Top").tag("top")
      }
      .pickerStyle(.segmented)

      Picker("Title Position", selection: Binding(
        get: { control.customFields["volumeTitlePosition"] ?? "top" },
        set: { control.customFields["volumeTitlePosition"] = $0 }
      )) {
        Text("Top").tag("top")
        Text("Bottom").tag("bottom")
        Text("Hidden").tag("hidden")
      }
      .pickerStyle(.segmented)

      Picker("Visibility", selection: Binding(
        get: { control.customFields["volumeLevelVisibility"] ?? "visible" },
        set: { control.customFields["volumeLevelVisibility"] = $0 }
      )) {
        Text("Visible").tag("visible")
        Text("Hidden (Long Press)").tag("hidden")
      }
      .pickerStyle(.segmented)
    }
  }

  private var volumeLevelPerLevelSection: some View {
    let count = Int(control.customFields["volumeLevelCount"] ?? "") ?? 8
    let cmds = modelStore.draft.commands

    return Section(header:
      HStack {
        Text("Per-Level Config")
        Spacer()
        Text("Label · Command").font(.caption).foregroundStyle(.secondary)
      }
    ) {
      if cmds.isEmpty {
        Label("Add commands in the Devices tab first", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
      }

      ForEach(0..<count, id: \.self) { i in
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 6) {
            Text("Level \(i)")
              .font(.system(.caption, design: .monospaced).weight(.semibold))
              .foregroundStyle(.secondary)
              .frame(width: 52, alignment: .leading)

            TextField(volumeLevelDefaultLabel(index: i, count: count),
              text: volumeLevelLabelBinding(index: i, count: count))
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
          }

          if !cmds.isEmpty {
            Picker("Command", selection: volumeLevelCommandIDBinding(index: i, count: count)) {
              Text("— None —").tag(UUID())
              ForEach(cmds) { cmd in
                Text("\(cmd.name) (\(cmd.payload.prefix(20))\(cmd.payload.count > 20 ? "…" : ""))")
                  .tag(cmd.id)
              }
            }
            .font(.caption)
          }
        }
        .padding(.vertical, 2)
      }
    }
  }

  private func volumeLevelDefaultLabel(index: Int, count: Int) -> String {
    return "\(index)"
  }

  private func volumeLevelLabelBinding(index: Int, count: Int) -> Binding<String> {
    Binding(
      get: {
        guard let json = control.customFields["volumeLevelLabels"],
              let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String],
              index < arr.count
        else { return volumeLevelDefaultLabel(index: index, count: count) }
        return arr[index]
      },
      set: { newVal in
        var arr: [String]
        if let json = control.customFields["volumeLevelLabels"],
           let data = json.data(using: .utf8),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String] {
          arr = existing
        } else {
          arr = (0..<count).map { volumeLevelDefaultLabel(index: $0, count: count) }
        }
        while arr.count <= index { arr.append(volumeLevelDefaultLabel(index: arr.count, count: count)) }
        arr[index] = newVal
        if let data = try? JSONSerialization.data(withJSONObject: arr),
           let s = String(data: data, encoding: .utf8) {
          control.customFields["volumeLevelLabels"] = s
        }
      }
    )
  }

  private func volumeLevelCommandIDBinding(index: Int, count: Int) -> Binding<UUID> {
    Binding(
      get: {
        guard let json = control.customFields["volumeLevelCommandIDs"],
              let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String],
              index < arr.count,
              let uuid = UUID(uuidString: arr[index])
        else { return UUID() }
        return uuid
      },
      set: { newID in
        var arr: [String]
        if let json = control.customFields["volumeLevelCommandIDs"],
           let data = json.data(using: .utf8),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String] {
          arr = existing
        } else {
          arr = Array(repeating: "", count: count)
        }
        while arr.count <= index { arr.append("") }
        arr[index] = newID.uuidString
        if let data = try? JSONSerialization.data(withJSONObject: arr),
           let s = String(data: data, encoding: .utf8) {
          control.customFields["volumeLevelCommandIDs"] = s
        }
      }
    )
  }

  private var volumeLevelStyleSection: some View {
    Section("Appearance") {
      Picker("Level Color", selection: Binding(
        get: { control.customFields["volumeActiveColor"] ?? "green" },
        set: { control.customFields["volumeActiveColor"] = $0 }
      )) {
        ForEach(volumeColorChoices, id: \.self) { c in Text(c.capitalized).tag(c) }
      }

      Picker("Track Color", selection: Binding(
        get: { control.customFields["volumeInactiveColor"] ?? "gray" },
        set: { control.customFields["volumeInactiveColor"] = $0 }
      )) {
        ForEach(volumeColorChoices, id: \.self) { c in Text(c.capitalized).tag(c) }
      }
    }
  }

  private let volumeColorChoices = [
    "white", "black", "gray", "blue", "green", "orange", "red",
    "cyan", "yellow", "purple", "pink", "mint", "teal",
  ]

  // MARK: Icon Style

  private let iconCategories: [(name: String, symbols: [String])] = [
    ("电源 / 控制", [
      "power.circle", "power", "switch.2", "togglepower",
      "button.programmable", "power.dotted", "powerplug", "powerplug.fill",
    ]),
    ("音视频", [
      "speaker.wave.2", "speaker.wave.3", "speaker.slash", "speaker",
      "mic", "mic.slash", "mic.circle",
      "video", "video.slash", "video.circle", "video.badge.waveform",
      "play.circle", "pause.circle", "stop.circle", "record.circle",
      "forward.circle", "backward.circle",
      "tv", "tv.circle", "display", "airplayvideo",
      "hifispeaker", "hifispeaker.2", "headphones", "earbuds",
      "radio", "antenna.radiowaves.left.and.right",
    ]),
    ("灯光", [
      "lightbulb", "lightbulb.circle", "lightbulb.2",
      "sun.max", "sun.min", "moon", "moon.circle",
      "light.recessed", "lamp.desk", "lamp.floor", "lamp.ceiling",
      "light.strip.leftthird.filled", "theatermasks",
    ]),
    ("网络 / 信号", [
      "wifi.circle", "wifi", "wifi.slash", "wifi.exclamationmark",
      "network", "bolt.horizontal.circle",
      "cable.connector", "cable.connector.horizontal",
      "dot.radiowaves.left.and.right", "dot.radiowaves.right",
      "antenna.radiowaves.left.and.right.slash",
    ]),
    ("系统 / 设置", [
      "gearshape", "gearshape.2", "gear.badge",
      "lock", "lock.open", "lock.circle", "key",
      "bell", "bell.slash", "bell.circle",
      "eye", "eye.slash", "eye.circle",
      "bolt", "bolt.circle", "bolt.slash",
      "shield", "shield.slash", "exclamationmark.shield",
    ]),
    ("通用", [
      "star", "star.circle", "heart", "heart.circle",
      "checkmark.circle", "xmark.circle", "plus.circle", "minus.circle",
      "arrow.triangle.2.circlepath", "arrow.up.arrow.down.circle",
      "arrow.clockwise.circle", "arrow.counterclockwise.circle",
      "hand.raised", "hand.thumbsup", "hand.thumbsdown",
      "flag", "flag.circle", "tag", "tag.circle",
    ]),
  ]

  // MARK: Matrix Config

  private var matrixConfigSection: some View {
    Group {
      matrixInputOutputColumnsDisclosure
      matrixCommandSection
      matrixChipStyleSection
      matrixPerChipSizeSection
      matrixPerChipOffsetSection
    }
  }

  private var matrixInputOutputColumnsDisclosure: some View {
    DisclosureGroup(isExpanded: $matrixIOColumnsExpanded) {
      matrixChannelSection
      matrixNamesSection
    } label: {
      Label("Input / output columns", systemImage: "rectangle.split.3x3")
    }
  }

  private var matrixChannelSection: some View {
    Section("Channels") {
      Stepper(
        "Inputs: \(Int(control.customFields["matrixInputCount"] ?? "") ?? 4)",
        value: Binding(
          get: { Double(Int(control.customFields["matrixInputCount"] ?? "") ?? 4) },
          set: { control.customFields["matrixInputCount"] = String(Int($0)) }
        ),
        in: 1...16, step: 1
      )

      Stepper(
        "Outputs: \(Int(control.customFields["matrixOutputCount"] ?? "") ?? 4)",
        value: Binding(
          get: { Double(Int(control.customFields["matrixOutputCount"] ?? "") ?? 4) },
          set: { control.customFields["matrixOutputCount"] = String(Int($0)) }
        ),
        in: 1...16, step: 1
      )

      TextField("Input Prefix", text: Binding(
        get: { control.customFields["matrixInputPrefix"] ?? "IN" },
        set: { control.customFields["matrixInputPrefix"] = $0 }
      ))

      TextField("Output Prefix", text: Binding(
        get: { control.customFields["matrixOutputPrefix"] ?? "OUT" },
        set: { control.customFields["matrixOutputPrefix"] = $0 }
      ))
    }
  }

  private var matrixNamesSection: some View {
    let inCount  = Int(control.customFields["matrixInputCount"]  ?? "") ?? 4
    let outCount = Int(control.customFields["matrixOutputCount"] ?? "") ?? 4
    let inPrefix  = control.customFields["matrixInputPrefix"]  ?? "IN"
    let outPrefix = control.customFields["matrixOutputPrefix"] ?? "OUT"

    return Group {
      Section(header:
        HStack {
          Text("Output Names (Displays)")
          Spacer()
          Text("Name · ID").font(.caption).foregroundStyle(.secondary)
        }
      ) {
        ForEach(0..<outCount, id: \.self) { i in
          HStack(spacing: 10) {
            Text("\(i + 1)")
              .foregroundStyle(.secondary)
              .frame(width: 22, alignment: .trailing)
              .font(.system(.body, design: .monospaced))
            TextField("\(outPrefix)\(i + 1)",
              text: matrixNameBinding(key: "matrixOutputNames", index: i,
                                      count: outCount, prefix: outPrefix))
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
            Divider().frame(height: 20)
            let idBinding = matrixCmdBinding(key: "matrixOutputCmds", index: i, count: outCount, idPrefix: outPrefix)
            VStack(alignment: .trailing, spacing: 1) {
              TextField("ID",
                text: Binding(
                  get: { idBinding.wrappedValue },
                  set: { idBinding.wrappedValue = String($0.filter { $0.isLetter || $0.isNumber }.prefix(12)) }
                ))
                .frame(width: 108)
                .multilineTextAlignment(.center)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
              Text("\(idBinding.wrappedValue.count)/12")
                .font(.system(size: 9))
                .foregroundStyle(idBinding.wrappedValue.count >= 12 ? .orange : .secondary)
            }
          }
        }
      }

      Section(header:
        HStack {
          Text("Input Names (Video Sources)")
          Spacer()
          Text("Name · ID").font(.caption).foregroundStyle(.secondary)
        }
      ) {
        ForEach(0..<inCount, id: \.self) { i in
          HStack(spacing: 10) {
            Text("\(i + 1)")
              .foregroundStyle(.secondary)
              .frame(width: 22, alignment: .trailing)
              .font(.system(.body, design: .monospaced))
            TextField("\(inPrefix)\(i + 1)",
              text: matrixNameBinding(key: "matrixInputNames", index: i,
                                      count: inCount, prefix: inPrefix))
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
            Divider().frame(height: 20)
            let idBinding = matrixCmdBinding(key: "matrixInputCmds", index: i, count: inCount, idPrefix: inPrefix)
            VStack(alignment: .trailing, spacing: 1) {
              TextField("ID",
                text: Binding(
                  get: { idBinding.wrappedValue },
                  set: { idBinding.wrappedValue = String($0.filter { $0.isLetter || $0.isNumber }.prefix(12)) }
                ))
                .frame(width: 108)
                .multilineTextAlignment(.center)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
              Text("\(idBinding.wrappedValue.count)/12")
                .font(.system(size: 9))
                .foregroundStyle(idBinding.wrappedValue.count >= 12 ? .orange : .secondary)
            }
          }
        }
      }
    }
  }

  private func matrixNameBinding(key: String, index: Int, count: Int, prefix: String) -> Binding<String> {
    Binding(
      get: {
        guard let json = control.customFields[key],
              let data = json.data(using: .utf8),
              let arr  = try? JSONSerialization.jsonObject(with: data) as? [String],
              index < arr.count
        else { return "\(prefix)\(index + 1)" }
        return arr[index]
      },
      set: { newVal in
        var arr: [String]
        if let json = control.customFields[key],
           let data = json.data(using: .utf8),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String] {
          arr = existing
        } else {
          arr = (0..<count).map { "\(prefix)\($0 + 1)" }
        }
        while arr.count <= index { arr.append("\(prefix)\(arr.count + 1)") }
        arr[index] = newVal
        if let data = try? JSONSerialization.data(withJSONObject: arr),
           let s = String(data: data, encoding: .utf8) {
          control.customFields[key] = s
        }
      }
    )
  }

  private func matrixCmdBinding(key: String, index: Int, count: Int, idPrefix: String? = nil) -> Binding<String> {
    Binding(
      get: {
        guard let json = control.customFields[key],
              let data = json.data(using: .utf8),
              let arr  = try? JSONSerialization.jsonObject(with: data) as? [String],
              index < arr.count
        else {
          if let idPrefix { return "\(idPrefix)\(index + 1)" }
          return "\(index + 1)"
        }
        return arr[index]
      },
      set: { newVal in
        var arr: [String]
        if let json = control.customFields[key],
           let data = json.data(using: .utf8),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String] {
          arr = existing
        } else if let idPrefix {
          arr = (0..<count).map { "\(idPrefix)\($0 + 1)" }
        } else {
          arr = (0..<count).map { "\($0 + 1)" }
        }
        while arr.count <= index {
          if let idPrefix {
            arr.append("\(idPrefix)\(arr.count + 1)")
          } else {
            arr.append("\(arr.count + 1)")
          }
        }
        arr[index] = newVal
        if let data = try? JSONSerialization.data(withJSONObject: arr),
           let s = String(data: data, encoding: .utf8) {
          control.customFields[key] = s
        }
      }
    )
  }

  private func matrixFirstID(key: String, fallback: String) -> String {
    guard let json = control.customFields[key],
          let data = json.data(using: .utf8),
          let arr  = try? JSONSerialization.jsonObject(with: data) as? [String],
          let first = arr.first, !first.isEmpty
    else { return fallback }
    return first
  }

  private var matrixCommandSection: some View {
    let template   = control.customFields["matrixCommandTemplate"] ?? "{output} VS {input}"
    let firstInID  = matrixFirstID(key: "matrixInputCmds", fallback: "IN1")
    let firstOutID = matrixFirstID(key: "matrixOutputCmds", fallback: "OUT1")
    let preview    = template
      .replacingOccurrences(of: "{input}",  with: firstInID)
      .replacingOccurrences(of: "{output}", with: firstOutID)

    return Section("Command") {
      VStack(alignment: .leading, spacing: 4) {
        Text("Command Template")
          .font(.caption)
          .foregroundStyle(.secondary)
        TextField("{output} VS {input}", text: Binding(
          get: { control.customFields["matrixCommandTemplate"] ?? "{output} VS {input}" },
          set: { control.customFields["matrixCommandTemplate"] = $0 }
        ))
        .font(.system(.body, design: .monospaced))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()

        Text("{input} → Input Cmd ID, {output} → Output Cmd ID")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }

      VStack(alignment: .leading, spacing: 3) {
        Text("Preview (first input→output)")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(preview)
          .font(.system(.callout, design: .monospaced))
          .foregroundStyle(.primary)
          .lineLimit(2)
          .textSelection(.enabled)
      }

      Picker("Line Ending", selection: Binding(
        get: { LineEnding(rawValue: control.customFields["matrixLineEnding"] ?? "crlf") ?? .crlf },
        set: { control.customFields["matrixLineEnding"] = $0.rawValue }
      )) {
        ForEach(LineEnding.allCases) { ending in
          Text(ending.displayName).tag(ending)
        }
      }

      Stepper(
        "Timeout: \(Int(control.customFields["matrixTimeoutMs"] ?? "") ?? 1500) ms",
        value: Binding(
          get: { Double(Int(control.customFields["matrixTimeoutMs"] ?? "") ?? 1500) },
          set: { control.customFields["matrixTimeoutMs"] = String(Int($0)) }
        ),
        in: 100...10000, step: 100
      )
    }
  }

  private var matrixChipStyleSection: some View {
    Section("Chip Style") {
      Stepper(
        "Width: \(Int(Double(control.customFields["matrixChipWidth"] ?? "") ?? 80))",
        value: Binding(
          get: { Double(control.customFields["matrixChipWidth"] ?? "") ?? 80 },
          set: { control.customFields["matrixChipWidth"] = String(Int($0)) }
        ),
        in: 40...200, step: 5
      )

      Stepper(
        "Height: \(Int(Double(control.customFields["matrixChipHeight"] ?? "") ?? 52))",
        value: Binding(
          get: { Double(control.customFields["matrixChipHeight"] ?? "") ?? 52 },
          set: { control.customFields["matrixChipHeight"] = String(Int($0)) }
        ),
        in: 24...300, step: 4
      )

      Stepper(
        "Chip Spacing: \(Int(Double(control.customFields["matrixChipSpacing"] ?? "") ?? 6))",
        value: Binding(
          get: { Double(control.customFields["matrixChipSpacing"] ?? "") ?? 6 },
          set: { control.customFields["matrixChipSpacing"] = String(Int($0)) }
        ),
        in: 0...30, step: 1
      )

      Stepper(
        "Title Size: \(Int(Double(control.customFields["matrixTitleFontSize"] ?? "") ?? 11))",
        value: Binding(
          get: { Double(control.customFields["matrixTitleFontSize"] ?? "") ?? 11 },
          set: { control.customFields["matrixTitleFontSize"] = String(Int($0)) }
        ),
        in: 8...60, step: 1
      )

      Stepper(
        "Title–Chip Gap: \(Int(Double(control.customFields["matrixTitleChipSpacing"] ?? "") ?? 10))",
        value: Binding(
          get: { Double(control.customFields["matrixTitleChipSpacing"] ?? "") ?? 10 },
          set: { control.customFields["matrixTitleChipSpacing"] = String(Int($0)) }
        ),
        in: 0...40, step: 2
      )

      Stepper(
        "Section Spacing: \(Int(Double(control.customFields["matrixSectionSpacing"] ?? "") ?? 8))",
        value: Binding(
          get: { Double(control.customFields["matrixSectionSpacing"] ?? "") ?? 8 },
          set: { control.customFields["matrixSectionSpacing"] = String(Int($0)) }
        ),
        in: 0...60, step: 2
      )

      Stepper(
        "Chip Font Size: \(Int(Double(control.customFields["matrixFontSize"] ?? "") ?? 14))",
        value: Binding(
          get: { Double(control.customFields["matrixFontSize"] ?? "") ?? 14 },
          set: { control.customFields["matrixFontSize"] = String(Int($0)) }
        ),
        in: 8...60, step: 1
      )

      Picker("Font Weight", selection: Binding(
        get: { control.customFields["matrixFontWeight"] ?? "semibold" },
        set: { control.customFields["matrixFontWeight"] = $0 }
      )) {
        Text("Regular").tag("regular")
        Text("Medium").tag("medium")
        Text("Semibold").tag("semibold")
        Text("Bold").tag("bold")
      }

      ColorPicker("Text Color", selection: Binding(
        get: { MatrixNamesHelper.parseColor(control.customFields["matrixTextColor"] ?? "white") },
        set: { control.customFields["matrixTextColor"] = $0.toHexString() }
      ), supportsOpacity: false)

      Picker("Text Preset", selection: Binding(
        get: { control.customFields["matrixTextColor"] ?? "white" },
        set: { control.customFields["matrixTextColor"] = $0 }
      )) {
        ForEach(matrixColorChoices, id: \.self) { c in Text(c.capitalized).tag(c) }
      }

      ColorPicker("Input Color", selection: Binding(
        get: { MatrixNamesHelper.parseColor(control.customFields["matrixInputColor"] ?? "blue") },
        set: { control.customFields["matrixInputColor"] = $0.toHexString() }
      ), supportsOpacity: false)

      Picker("Input Preset", selection: Binding(
        get: { control.customFields["matrixInputColor"] ?? "blue" },
        set: { control.customFields["matrixInputColor"] = $0 }
      )) {
        ForEach(matrixColorChoices, id: \.self) { c in Text(c.capitalized).tag(c) }
      }

      ColorPicker("Output Color", selection: Binding(
        get: { MatrixNamesHelper.parseColor(control.customFields["matrixOutputColor"] ?? "green") },
        set: { control.customFields["matrixOutputColor"] = $0.toHexString() }
      ), supportsOpacity: false)

      Picker("Output Preset", selection: Binding(
        get: { control.customFields["matrixOutputColor"] ?? "green" },
        set: { control.customFields["matrixOutputColor"] = $0 }
      )) {
        ForEach(matrixColorChoices, id: \.self) { c in Text(c.capitalized).tag(c) }
      }

      ColorPicker("Border Color", selection: Binding(
        get: {
          MatrixNamesHelper.optionalMatrixColor(control.customFields, key: "matrixBorderColor")
            ?? MatrixNamesHelper.parseColor(control.customFields["matrixInputColor"] ?? "blue")
        },
        set: { control.customFields["matrixBorderColor"] = $0.toHexString() }
      ), supportsOpacity: false)

      Picker("Border Preset", selection: Binding(
        get: { control.customFields["matrixBorderColor"] ?? "" },
        set: { control.customFields["matrixBorderColor"] = $0.isEmpty ? nil : $0 }
      )) {
        Text("Auto (Input/Output)").tag("")
        ForEach(matrixColorChoices, id: \.self) { c in Text(c.capitalized).tag(c) }
      }

      ColorPicker("Drag / Highlight Color", selection: Binding(
        get: {
          MatrixNamesHelper.matrixDragColor(
            in: control.customFields,
            fallback: MatrixNamesHelper.parseColor(control.customFields["matrixInputColor"] ?? "blue"))
        },
        set: { control.customFields["matrixDragColor"] = $0.toHexString() }
      ), supportsOpacity: false)

      Picker("Drag Preset", selection: Binding(
        get: { control.customFields["matrixDragColor"] ?? "" },
        set: { control.customFields["matrixDragColor"] = $0.isEmpty ? nil : $0 }
      )) {
        Text("Auto (Input Color)").tag("")
        ForEach(matrixColorChoices, id: \.self) { c in Text(c.capitalized).tag(c) }
      }

      Text("Border: chip outline. Drag: ghost chip, drag highlight, drop target.")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
  }

  private var matrixPerChipSizeSection: some View {
    let inputCount  = max(1, Int(control.customFields["matrixInputCount"]  ?? "") ?? 4)
    let outputCount = max(1, Int(control.customFields["matrixOutputCount"] ?? "") ?? 4)
    let defaultW = CGFloat(Double(control.customFields["matrixChipWidth"] ?? "") ?? 80)
    let defaultH = CGFloat(Double(control.customFields["matrixChipHeight"] ?? "") ?? 52)
    let inputNames  = MatrixNamesHelper.parseNames(control.customFields["matrixInputNames"], count: inputCount, prefix: control.customFields["matrixInputPrefix"] ?? "IN")
    let outputNames = MatrixNamesHelper.parseNames(control.customFields["matrixOutputNames"], count: outputCount, prefix: control.customFields["matrixOutputPrefix"] ?? "OUT")

    return Group {
      Section("Per-Input Sizes") {
        ForEach(0..<inputCount, id: \.self) { i in
          perChipSizeRow(
            label: inputNames[i], index: i,
            widthsKey: "matrixInputWidths", heightsKey: "matrixInputHeights",
            count: inputCount, defaultW: defaultW, defaultH: defaultH,
            wRange: 30...300, hRange: 20...300
          )
        }
        Button("Reset All to Default") {
          control.customFields.removeValue(forKey: "matrixInputWidths")
          control.customFields.removeValue(forKey: "matrixInputHeights")
        }
        .foregroundStyle(.red)
      }

      Section("Per-Output Sizes") {
        ForEach(0..<outputCount, id: \.self) { i in
          perChipSizeRow(
            label: outputNames[i], index: i,
            widthsKey: "matrixOutputWidths", heightsKey: "matrixOutputHeights",
            count: outputCount, defaultW: defaultW, defaultH: defaultH,
            wRange: 30...300, hRange: 20...300
          )
        }
        Button("Reset All to Default") {
          control.customFields.removeValue(forKey: "matrixOutputWidths")
          control.customFields.removeValue(forKey: "matrixOutputHeights")
        }
        .foregroundStyle(.red)
      }
    }
  }

  private func perChipSizeRow(
    label: String, index: Int,
    widthsKey: String, heightsKey: String,
    count: Int, defaultW: CGFloat, defaultH: CGFloat,
    wRange: ClosedRange<Double>, hRange: ClosedRange<Double>
  ) -> some View {
    let widths = MatrixNamesHelper.parseSizes(control.customFields[widthsKey], count: count, fallback: defaultW)
    let heights = MatrixNamesHelper.parseSizes(control.customFields[heightsKey], count: count, fallback: defaultH)

    return VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.subheadline.weight(.medium))
      HStack(spacing: 12) {
        Stepper(
          "W: \(Int(widths[index]))",
          value: Binding(
            get: { Double(widths[index]) },
            set: { newVal in
              var arr = widths
              arr[index] = CGFloat(newVal)
              control.customFields[widthsKey] = MatrixNamesHelper.encodeSizes(arr)
            }
          ),
          in: wRange, step: 5
        )
        Stepper(
          "H: \(Int(heights[index]))",
          value: Binding(
            get: { Double(heights[index]) },
            set: { newVal in
              var arr = heights
              arr[index] = CGFloat(newVal)
              control.customFields[heightsKey] = MatrixNamesHelper.encodeSizes(arr)
            }
          ),
          in: hRange, step: 4
        )
      }
    }
  }

  private func perChipOffsetRow(
    label: String, index: Int,
    xKey: String, yKey: String,
    count: Int
  ) -> some View {
    let xs = MatrixNamesHelper.parseSizes(control.customFields[xKey], count: count, fallback: 0)
    let ys = MatrixNamesHelper.parseSizes(control.customFields[yKey], count: count, fallback: 0)

    return VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.subheadline.weight(.medium))
      HStack(spacing: 12) {
        Stepper(
          "X: \(Int(xs[index]))",
          value: Binding(
            get: { Double(xs[index]) },
            set: { newVal in
              var arr = xs
              arr[index] = CGFloat(newVal)
              control.customFields[xKey] = MatrixNamesHelper.encodeSizes(arr)
            }
          ),
          in: -500...500, step: 2
        )
        Stepper(
          "Y: \(Int(ys[index]))",
          value: Binding(
            get: { Double(ys[index]) },
            set: { newVal in
              var arr = ys
              arr[index] = CGFloat(newVal)
              control.customFields[yKey] = MatrixNamesHelper.encodeSizes(arr)
            }
          ),
          in: -500...500, step: 2
        )
      }
    }
  }

  private var matrixPerChipOffsetSection: some View {
    let inputCount  = max(1, Int(control.customFields["matrixInputCount"]  ?? "") ?? 4)
    let outputCount = max(1, Int(control.customFields["matrixOutputCount"] ?? "") ?? 4)
    let inputNames  = MatrixNamesHelper.parseNames(control.customFields["matrixInputNames"], count: inputCount, prefix: control.customFields["matrixInputPrefix"] ?? "IN")
    let outputNames = MatrixNamesHelper.parseNames(control.customFields["matrixOutputNames"], count: outputCount, prefix: control.customFields["matrixOutputPrefix"] ?? "OUT")

    return Group {
      Section("Per-Input Offsets") {
        ForEach(0..<inputCount, id: \.self) { i in
          perChipOffsetRow(
            label: inputNames[i], index: i,
            xKey: "matrixInputOffsetX", yKey: "matrixInputOffsetY",
            count: inputCount
          )
        }
        Button("Reset All to Default") {
          control.customFields.removeValue(forKey: "matrixInputOffsetX")
          control.customFields.removeValue(forKey: "matrixInputOffsetY")
        }
        .foregroundStyle(.red)
      }

      Section("Per-Output Offsets") {
        ForEach(0..<outputCount, id: \.self) { i in
          perChipOffsetRow(
            label: outputNames[i], index: i,
            xKey: "matrixOutputOffsetX", yKey: "matrixOutputOffsetY",
            count: outputCount
          )
        }
        Button("Reset All to Default") {
          control.customFields.removeValue(forKey: "matrixOutputOffsetX")
          control.customFields.removeValue(forKey: "matrixOutputOffsetY")
        }
        .foregroundStyle(.red)
      }
    }
  }

  private let matrixColorChoices = [
    "white", "black", "gray", "blue", "green", "orange", "red",
    "cyan", "yellow", "purple", "pink", "mint", "teal",
  ]

  private func matrixNamesToCSV(_ json: String?, count: Int, prefix: String) -> String {
    if let json, let data = json.data(using: .utf8),
      let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
    {
      return arr.joined(separator: ",")
    }
    return (1...count).map { "\(prefix)\($0)" }.joined(separator: ",")
  }

  private func matrixCmdsToCSV(_ json: String?, count: Int) -> String {
    if let json, let data = json.data(using: .utf8),
      let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
    {
      return arr.joined(separator: ",")
    }
    return (1...count).map { "\($0)" }.joined(separator: ",")
  }

  private func matrixCSVToJSON(_ csv: String) -> String {
    let items = csv.split(separator: ",", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
    guard let data = try? JSONSerialization.data(withJSONObject: items),
      let json = String(data: data, encoding: .utf8)
    else { return "[]" }
    return json
  }

  // MARK: Live Matrix Config

  private var liveMatrixConfigSection: some View {
    Group {
      liveMatrixInputOutputColumnsDisclosure
      liveMatrixSourcesSection
      liveMatrixDisplaysSection
      liveMatrixStreamServerSection
      liveMatrixCommandSection
      liveMatrixChipStyleSection
      liveMatrixPerChipSizeSection
      liveMatrixPerChipOffsetSection
    }
  }

  private var liveMatrixInputOutputColumnsDisclosure: some View {
    DisclosureGroup(isExpanded: $matrixIOColumnsExpanded) {
      liveMatrixChannelSection
    } label: {
      Label(L10n.lmEditorIOColumns, systemImage: "rectangle.split.3x3")
    }
  }

  private var liveMatrixChannelSection: some View {
    Section("Channels") {
      Picker("Layout", selection: Binding(
        get: { control.customFields["liveMatrixLayout"] ?? "horizontal" },
        set: { control.customFields["liveMatrixLayout"] = $0 }
      )) {
        Label("Horizontal", systemImage: "rectangle.split.2x1").tag("horizontal")
        Label("Vertical", systemImage: "rectangle.split.1x2").tag("vertical")
      }
      .pickerStyle(.segmented)

      Stepper(
        "Inputs: \(Int(control.customFields["liveMatrixInputCount"] ?? "") ?? 4)",
        value: Binding(
          get: { Double(Int(control.customFields["liveMatrixInputCount"] ?? "") ?? 4) },
          set: { newVal in
            let old = Int(control.customFields["liveMatrixInputCount"] ?? "") ?? 4
            let new = Int(newVal)
            guard new != old else { return }
            let oldOut = Int(control.customFields["liveMatrixOutputCount"] ?? "") ?? 4
            syncLiveMatrixChannelArrays(oldIn: old, oldOut: oldOut, newIn: new, newOut: oldOut)
            if new > old { channelCountNotice = L10n.lmEditorChannelsAdded(new - old) }
            control.customFields["liveMatrixInputCount"] = String(new)
          }
        ),
        in: 1...16, step: 1
      )

      Stepper(
        "Outputs: \(Int(control.customFields["liveMatrixOutputCount"] ?? "") ?? 4)",
        value: Binding(
          get: { Double(Int(control.customFields["liveMatrixOutputCount"] ?? "") ?? 4) },
          set: { newVal in
            let oldIn = Int(control.customFields["liveMatrixInputCount"] ?? "") ?? 4
            let old = Int(control.customFields["liveMatrixOutputCount"] ?? "") ?? 4
            let new = Int(newVal)
            guard new != old else { return }
            syncLiveMatrixChannelArrays(oldIn: oldIn, oldOut: old, newIn: oldIn, newOut: new)
            control.customFields["liveMatrixOutputCount"] = String(new)
          }
        ),
        in: 1...16, step: 1
      )

      TextField("Input Prefix", text: Binding(
        get: { control.customFields["liveMatrixInputPrefix"] ?? "Tx" },
        set: { control.customFields["liveMatrixInputPrefix"] = $0 }
      ))

      TextField("Output Prefix", text: Binding(
        get: { control.customFields["liveMatrixOutputPrefix"] ?? "Rx" },
        set: { control.customFields["liveMatrixOutputPrefix"] = $0 }
      ))
    }
  }

  private var liveMatrixStreamServerSection: some View {
    Section {
      TextField("Server Host (e.g. 192.168.2.112)", text: Binding(
        get: { control.customFields["liveMatrixStreamServerHost"] ?? "" },
        set: { control.customFields["liveMatrixStreamServerHost"] = $0 }
      ))
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .keyboardType(.numbersAndPunctuation)

      TextField("Server Port (e.g. 10085)", text: Binding(
        get: { control.customFields["liveMatrixStreamServerPort"] ?? "10085" },
        set: { control.customFields["liveMatrixStreamServerPort"] = $0 }
      ))
      .keyboardType(.numberPad)

      Stepper(
        "Width: \(control.customFields["liveMatrixStreamWidth"] ?? "960")",
        value: Binding(
          get: { Double(control.customFields["liveMatrixStreamWidth"] ?? "") ?? 960 },
          set: { control.customFields["liveMatrixStreamWidth"] = String(Int($0)) }
        ),
        in: 160...3840, step: 160
      )

      Stepper(
        "Height: \(control.customFields["liveMatrixStreamHeight"] ?? "540")",
        value: Binding(
          get: { Double(control.customFields["liveMatrixStreamHeight"] ?? "") ?? 540 },
          set: { control.customFields["liveMatrixStreamHeight"] = String(Int($0)) }
        ),
        in: 90...2160, step: 90
      )

      Stepper(
        "FPS: \(control.customFields["liveMatrixStreamFps"] ?? "30")",
        value: Binding(
          get: { Double(control.customFields["liveMatrixStreamFps"] ?? "") ?? 30 },
          set: { control.customFields["liveMatrixStreamFps"] = String(Int($0)) }
        ),
        in: 1...60, step: 1
      )

      Stepper(
        "Bandwidth: \(control.customFields["liveMatrixStreamBw"] ?? "8000") kbps",
        value: Binding(
          get: { Double(control.customFields["liveMatrixStreamBw"] ?? "") ?? 8000 },
          set: { control.customFields["liveMatrixStreamBw"] = String(Int($0)) }
        ),
        in: 500...50000, step: 500
      )
    } header: {
      Text("Stream Server")
    } footer: {
      Text("All devices share the same stream server host and port.")
        .font(.caption)
    }
  }

  private var liveMatrixSourcesSection: some View {
    let inCount = Int(control.customFields["liveMatrixInputCount"] ?? "") ?? 4
    let inPrefix = control.customFields["liveMatrixInputPrefix"] ?? "Tx"
    let serverHost = control.customFields["liveMatrixStreamServerHost"] ?? ""
    let serverMissing = serverHost.trimmingCharacters(in: .whitespaces).isEmpty

    return Section {
      if serverMissing {
        Text(L10n.lmEditorStreamServerRequired)
          .font(.caption)
          .foregroundStyle(.orange)
      }
      if let notice = channelCountNotice {
        Text(notice)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      ForEach(0..<inCount, id: \.self) { i in
        liveMatrixInputChannelRow(index: i, inCount: inCount, inPrefix: inPrefix)
      }
    } header: {
      HStack {
        Text(L10n.liveMatrixSources)
        Spacer()
        Text(L10n.lmEditorMacIpPort).font(.caption).foregroundStyle(.secondary)
        Button {
          Task { await fetchDeviceList(for: .encoder) }
        } label: {
          if fetchingDeviceList {
            ProgressView().controlSize(.small)
          } else {
            Text(L10n.lmEditorFetchDevicelist)
              .font(.caption)
          }
        }
        .buttonStyle(.borderless)
        .disabled(fetchingDeviceList)
        Button {
          Task { await fetchAllInputDeviceInfo(inCount: inCount) }
        } label: {
          if fetchingAllInputs {
            ProgressView().controlSize(.small)
          } else {
            Text(L10n.lmEditorFetchAll)
              .font(.caption)
          }
        }
        .buttonStyle(.borderless)
        .disabled(fetchingAllInputs)
      }
    } footer: {
      VStack(alignment: .leading, spacing: 4) {
        if let deviceListError {
          Text(deviceListError)
            .font(.caption)
            .foregroundStyle(.red)
        } else if !discoveredEncoders.isEmpty {
          Text(L10n.lmEditorDevicelistEncodersCount(discoveredEncoders.count))
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text(L10n.lmEditorDevicelistEmpty)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text(L10n.lmEditorStreamFooter)
          .font(.caption)
      }
    }
  }

  @ViewBuilder
  private func liveMatrixInputChannelRow(index i: Int, inCount: Int, inPrefix: String) -> some View {
  VStack(alignment: .leading, spacing: 6) {
    HStack(spacing: 10) {
      Text("\(i + 1)")
        .foregroundStyle(.secondary)
        .frame(width: 22, alignment: .trailing)
        .font(.system(.body, design: .monospaced))
      TextField("\(inPrefix)\(i + 1)",
        text: matrixNameBinding(key: "liveMatrixInputNames", index: i,
                                count: inCount, prefix: inPrefix))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      Divider().frame(height: 20)
      let idBinding = matrixCmdBinding(key: "liveMatrixInputCmds", index: i, count: inCount)
      TextField(L10n.lmEditorRouteID, text: idBinding)
        .frame(width: 80)
        .multilineTextAlignment(.center)
        .font(.system(.body, design: .monospaced))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      let fetchKey = "in_\(i)"
      let cmdID = matrixCmdBinding(key: "liveMatrixInputCmds", index: i, count: inCount).wrappedValue
      Button {
        fetchError[fetchKey] = nil
        Task { await fetchDeviceInfo(cmdID: cmdID, isInput: true, index: i, count: inCount) }
      } label: {
        if fetchingInfo.contains(fetchKey) {
          ProgressView().frame(width: 22, height: 22)
        } else {
          Image(systemName: "arrow.clockwise.circle")
            .imageScale(.large)
        }
      }
      .buttonStyle(.borderless)
      .disabled(cmdID.trimmingCharacters(in: .whitespaces).isEmpty || fetchingInfo.contains(fetchKey))
    }

    if !discoveredEncoders.isEmpty {
      discoveredEncoderPicker(index: i, inCount: inCount)
    }

    TextField(L10n.lmEditorMacPlaceholder, text: liveMatrixJSONArrayBinding(key: "liveMatrixInputStreamDevIDs", index: i, count: inCount, fallback: ""))
      .textInputAutocapitalization(.characters)
      .autocorrectionDisabled()
      .keyboardType(.asciiCapable)
    HStack(spacing: 6) {
      TextField(L10n.lmEditorDeviceIP, text: liveMatrixJSONArrayBinding(key: "liveMatrixInputStreamIPs", index: i, count: inCount, fallback: ""))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(.numbersAndPunctuation)
      TextField(L10n.lmEditorStreamPort, text: liveMatrixJSONArrayBinding(key: "liveMatrixInputStreamPorts", index: i, count: inCount, fallback: "8080"))
        .frame(width: 70)
        .keyboardType(.numberPad)
    }

    let mac = liveMatrixJSONArrayBinding(key: "liveMatrixInputStreamDevIDs", index: i, count: inCount, fallback: "").wrappedValue
    let ip = liveMatrixJSONArrayBinding(key: "liveMatrixInputStreamIPs", index: i, count: inCount, fallback: "").wrappedValue
  if mac.trimmingCharacters(in: .whitespaces).isEmpty {
    Text(L10n.lmEditorMacEmptyWarning)
      .font(.caption2)
      .foregroundStyle(.orange)
  }
  if isSuspiciousLiveMatrixIP(ip) {
    Text(L10n.lmEditorIpInvalidWarning)
      .font(.caption2)
      .foregroundStyle(.orange)
  }
  if let err = fetchError["in_\(i)"] {
    Text(err)
      .font(.caption)
      .foregroundStyle(.red)
  }

  DisclosureGroup(
    isExpanded: Binding(
      get: { streamPreviewExpanded.contains(i) },
      set: { expanded in
        if expanded { streamPreviewExpanded.insert(i) }
        else { streamPreviewExpanded.remove(i) }
      }
    )
  ) {
    let port = liveMatrixJSONArrayBinding(key: "liveMatrixInputStreamPorts", index: i, count: inCount, fallback: "8080").wrappedValue
    let previewURL = LiveMatrixStreamURL.build(
      customFields: control.customFields,
      ip: ip,
      port: port.isEmpty ? "8080" : port,
      devID: mac
    )
    SharedMJPEGView(url: previewURL, cornerRadius: 6)
      .frame(height: 120)
      .padding(.vertical, 4)
  } label: {
    Text(L10n.lmEditorPreviewStream)
      .font(.caption)
  }
  }
  }

  private var liveMatrixDisplaysSection: some View {
    let outCount = Int(control.customFields["liveMatrixOutputCount"] ?? "") ?? 4
    let outPrefix = control.customFields["liveMatrixOutputPrefix"] ?? "Rx"
    let inCount = Int(control.customFields["liveMatrixInputCount"] ?? "") ?? 4
    let inPrefix = control.customFields["liveMatrixInputPrefix"] ?? "Tx"
    let inputNames = liveMatrixParsedNames(key: "liveMatrixInputNames", count: inCount, prefix: inPrefix)

    return Section {
      ForEach(0..<outCount, id: \.self) { i in
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 10) {
            Text("\(i + 1)")
              .foregroundStyle(.secondary)
              .frame(width: 22, alignment: .trailing)
              .font(.system(.body, design: .monospaced))
            TextField("\(outPrefix)\(i + 1)",
              text: matrixNameBinding(key: "liveMatrixOutputNames", index: i,
                                      count: outCount, prefix: outPrefix))
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
            Divider().frame(height: 20)
            TextField(L10n.lmEditorRouteID,
              text: matrixCmdBinding(key: "liveMatrixOutputCmds", index: i, count: outCount))
              .frame(width: 80)
              .multilineTextAlignment(.center)
              .font(.system(.body, design: .monospaced))
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
          }

          if !discoveredDecoders.isEmpty {
            discoveredDecoderPicker(index: i, outCount: outCount, outPrefix: outPrefix)
          }

          let blockedSet = MatrixNamesHelper.blockedInputs(
            forOutput: i, customFields: control.customFields, isLive: true)
          RouteBlacklistInline(
            blockedSet: blockedSet,
            inputCount: inCount,
            inputNames: inputNames,
            onToggle: { inIdx, shouldBlock in
              var newBlocked = blockedSet
              if shouldBlock { newBlocked.insert(inIdx) } else { newBlocked.remove(inIdx) }
              let newJson = MatrixNamesHelper.setBlockedInputs(
                newBlocked, forOutput: i,
                existing: control.customFields, isLive: true
              )
              control.customFields["liveMatrixOutputBlockedInputs"] = newJson
            }
          )
        }
      }
    } header: {
      HStack {
        Text(L10n.liveMatrixDisplays)
        Spacer()
        Text(L10n.lmEditorNameCmd).font(.caption).foregroundStyle(.secondary)
        Button {
          Task { await fetchDeviceList(for: .decoder) }
        } label: {
          if fetchingDeviceList {
            ProgressView().controlSize(.small)
          } else {
            Text(L10n.lmEditorFetchDevicelist)
              .font(.caption)
          }
        }
        .buttonStyle(.borderless)
        .disabled(fetchingDeviceList)
      }
    } footer: {
      VStack(alignment: .leading, spacing: 4) {
        if let deviceListError {
          Text(deviceListError)
            .font(.caption)
            .foregroundStyle(.red)
        } else if !discoveredDecoders.isEmpty {
          Text(L10n.lmEditorDevicelistDecodersCount(discoveredDecoders.count))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Text(L10n.lmEditorDisplayFooter)
          .font(.caption)
      }
    }
  }

  private func liveMatrixParsedNames(key: String, count: Int, prefix: String) -> [String] {
    if let json = control.customFields[key],
       let data = json.data(using: .utf8),
       let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
      var result = arr
      while result.count < count { result.append("\(prefix)\(result.count + 1)") }
      return Array(result.prefix(count))
    }
    return (1...count).map { "\(prefix)\($0)" }
  }

  private func liveMatrixJSONArrayBinding(key: String, index: Int, count: Int, fallback: String) -> Binding<String> {
    Binding(
      get: {
        guard let json = control.customFields[key],
              let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String],
              index < arr.count
        else { return fallback }
        return arr[index]
      },
      set: { newVal in
        var arr: [String]
        if let json = control.customFields[key],
           let data = json.data(using: .utf8),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String] {
          arr = existing
        } else {
          arr = Array(repeating: fallback, count: count)
        }
        while arr.count <= index { arr.append(fallback) }
        arr[index] = newVal
        if let data = try? JSONSerialization.data(withJSONObject: arr),
           let s = String(data: data, encoding: .utf8) {
          control.customFields[key] = s
        }
      }
    )
  }

  private var liveMatrixCommandSection: some View {
    let template   = control.customFields["liveMatrixCommandTemplate"] ?? "matrix aset :av {input} {output}"
    let firstInID  = liveMatrixFirstID(key: "liveMatrixInputCmds", fallback: "1")
    let firstOutID = liveMatrixFirstID(key: "liveMatrixOutputCmds", fallback: "1")
    let preview    = template
      .replacingOccurrences(of: "{input}",  with: firstInID)
      .replacingOccurrences(of: "{output}", with: firstOutID)

    return Section("Command") {
      VStack(alignment: .leading, spacing: 4) {
        Text("Command Template")
          .font(.caption)
          .foregroundStyle(.secondary)
        TextField("matrix aset :av {input} {output}", text: Binding(
          get: { control.customFields["liveMatrixCommandTemplate"] ?? "matrix aset :av {input} {output}" },
          set: { control.customFields["liveMatrixCommandTemplate"] = $0 }
        ))
        .font(.system(.body, design: .monospaced))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()

        Text("{input} → Input Cmd ID, {output} → Output Cmd ID")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }

      VStack(alignment: .leading, spacing: 3) {
        Text("Preview (first input→output)")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(preview)
          .font(.system(.callout, design: .monospaced))
          .foregroundStyle(.primary)
          .lineLimit(2)
          .textSelection(.enabled)
      }

      Picker("Line Ending", selection: Binding(
        get: { LineEnding(rawValue: control.customFields["liveMatrixLineEnding"] ?? "crlf") ?? .crlf },
        set: { control.customFields["liveMatrixLineEnding"] = $0.rawValue }
      )) {
        ForEach(LineEnding.allCases) { ending in
          Text(ending.displayName).tag(ending)
        }
      }

      Stepper(
        "Timeout: \(Int(control.customFields["liveMatrixTimeoutMs"] ?? "") ?? 1500) ms",
        value: Binding(
          get: { Double(Int(control.customFields["liveMatrixTimeoutMs"] ?? "") ?? 1500) },
          set: { control.customFields["liveMatrixTimeoutMs"] = String(Int($0)) }
        ),
        in: 100...10000, step: 100
      )
    }
  }

  private func liveMatrixFirstID(key: String, fallback: String) -> String {
    guard let json = control.customFields[key],
          let data = json.data(using: .utf8),
          let arr  = try? JSONSerialization.jsonObject(with: data) as? [String],
          let first = arr.first, !first.isEmpty
    else { return fallback }
    return first
  }

  private var liveMatrixChipStyleSection: some View {
    Section("Chip Style") {
      Stepper(
        "Chip Width: \(Int(Double(control.customFields["liveMatrixChipWidth"] ?? "") ?? 160))",
        value: Binding(
          get: { Double(control.customFields["liveMatrixChipWidth"] ?? "") ?? 160 },
          set: { control.customFields["liveMatrixChipWidth"] = String(Int($0)) }
        ),
        in: 60...400, step: 10
      )

      Stepper(
        "Chip Height: \(Int(Double(control.customFields["liveMatrixChipHeight"] ?? "") ?? 120))",
        value: Binding(
          get: { Double(control.customFields["liveMatrixChipHeight"] ?? "") ?? 120 },
          set: { control.customFields["liveMatrixChipHeight"] = String(Int($0)) }
        ),
        in: 40...300, step: 10
      )

      Stepper(
        "Output Preview Width: \(Int(Double(control.customFields["liveMatrixOutputChipWidth"] ?? "") ?? (Double(control.customFields["liveMatrixChipWidth"] ?? "") ?? 160)))",
        value: Binding(
          get: { Double(control.customFields["liveMatrixOutputChipWidth"] ?? "") ?? (Double(control.customFields["liveMatrixChipWidth"] ?? "") ?? 160) },
          set: { control.customFields["liveMatrixOutputChipWidth"] = String(Int($0)) }
        ),
        in: 60...500, step: 10
      )

      Stepper(
        "Output Preview Height: \(Int(Double(control.customFields["liveMatrixOutputChipHeight"] ?? "") ?? (Double(control.customFields["liveMatrixChipHeight"] ?? "") ?? 120)))",
        value: Binding(
          get: { Double(control.customFields["liveMatrixOutputChipHeight"] ?? "") ?? (Double(control.customFields["liveMatrixChipHeight"] ?? "") ?? 120) },
          set: { control.customFields["liveMatrixOutputChipHeight"] = String(Int($0)) }
        ),
        in: 40...400, step: 10
      )

      Stepper(
        "Chip Spacing: \(Int(Double(control.customFields["liveMatrixChipSpacing"] ?? "") ?? 8))",
        value: Binding(
          get: { Double(control.customFields["liveMatrixChipSpacing"] ?? "") ?? 8 },
          set: { control.customFields["liveMatrixChipSpacing"] = String(Int($0)) }
        ),
        in: 0...30, step: 1
      )

      Stepper(
        "Title–Chip Gap: \(Int(Double(control.customFields["liveMatrixTitleChipSpacing"] ?? "") ?? 8))",
        value: Binding(
          get: { Double(control.customFields["liveMatrixTitleChipSpacing"] ?? "") ?? 8 },
          set: { control.customFields["liveMatrixTitleChipSpacing"] = String(Int($0)) }
        ),
        in: 0...40, step: 2
      )

      Stepper(
        "Title Font Size: \(Int(Double(control.customFields["liveMatrixTitleFontSize"] ?? "") ?? 12))",
        value: Binding(
          get: { Double(control.customFields["liveMatrixTitleFontSize"] ?? "") ?? 12 },
          set: { control.customFields["liveMatrixTitleFontSize"] = String(Int($0)) }
        ),
        in: 8...40, step: 1
      )

      Stepper(
        "Chip Font Size: \(Int(Double(control.customFields["liveMatrixFontSize"] ?? "") ?? 12))",
        value: Binding(
          get: { Double(control.customFields["liveMatrixFontSize"] ?? "") ?? 12 },
          set: { control.customFields["liveMatrixFontSize"] = String(Int($0)) }
        ),
        in: 8...40, step: 1
      )

      Picker("Font Weight", selection: Binding(
        get: { control.customFields["liveMatrixFontWeight"] ?? "semibold" },
        set: { control.customFields["liveMatrixFontWeight"] = $0 }
      )) {
        Text("Regular").tag("regular")
        Text("Medium").tag("medium")
        Text("Semibold").tag("semibold")
        Text("Bold").tag("bold")
      }
    }
  }

  private var liveMatrixPerChipSizeSection: some View {
    let inputCount  = max(1, Int(control.customFields["liveMatrixInputCount"]  ?? "") ?? 4)
    let outputCount = max(1, Int(control.customFields["liveMatrixOutputCount"] ?? "") ?? 4)
    let defaultInW = CGFloat(Double(control.customFields["liveMatrixChipWidth"] ?? "") ?? 160)
    let defaultInH = CGFloat(Double(control.customFields["liveMatrixChipHeight"] ?? "") ?? 120)
    let defaultOutW = CGFloat(Double(control.customFields["liveMatrixOutputChipWidth"] ?? "") ?? Double(defaultInW))
    let defaultOutH = CGFloat(Double(control.customFields["liveMatrixOutputChipHeight"] ?? "") ?? Double(defaultInH))
    let inputNames  = MatrixNamesHelper.parseNames(control.customFields["liveMatrixInputNames"], count: inputCount, prefix: control.customFields["liveMatrixInputPrefix"] ?? "Tx")
    let outputNames = MatrixNamesHelper.parseNames(control.customFields["liveMatrixOutputNames"], count: outputCount, prefix: control.customFields["liveMatrixOutputPrefix"] ?? "Rx")

    return Group {
      Section("Per-Input Sizes") {
        ForEach(0..<inputCount, id: \.self) { i in
          perChipSizeRow(
            label: inputNames[i], index: i,
            widthsKey: "liveMatrixInputWidths", heightsKey: "liveMatrixInputHeights",
            count: inputCount, defaultW: defaultInW, defaultH: defaultInH,
            wRange: 40...500, hRange: 30...400
          )
        }
        Button("Reset All to Default") {
          control.customFields.removeValue(forKey: "liveMatrixInputWidths")
          control.customFields.removeValue(forKey: "liveMatrixInputHeights")
        }
        .foregroundStyle(.red)
      }

      Section("Per-Output Sizes") {
        ForEach(0..<outputCount, id: \.self) { i in
          perChipSizeRow(
            label: outputNames[i], index: i,
            widthsKey: "liveMatrixOutputWidths", heightsKey: "liveMatrixOutputHeights",
            count: outputCount, defaultW: defaultOutW, defaultH: defaultOutH,
            wRange: 40...500, hRange: 30...400
          )
        }
        Button("Reset All to Default") {
          control.customFields.removeValue(forKey: "liveMatrixOutputWidths")
          control.customFields.removeValue(forKey: "liveMatrixOutputHeights")
        }
        .foregroundStyle(.red)
      }
    }
  }

  private var liveMatrixPerChipOffsetSection: some View {
    let inputCount  = max(1, Int(control.customFields["liveMatrixInputCount"]  ?? "") ?? 4)
    let outputCount = max(1, Int(control.customFields["liveMatrixOutputCount"] ?? "") ?? 4)
    let inputNames  = MatrixNamesHelper.parseNames(control.customFields["liveMatrixInputNames"], count: inputCount, prefix: control.customFields["liveMatrixInputPrefix"] ?? "Tx")
    let outputNames = MatrixNamesHelper.parseNames(control.customFields["liveMatrixOutputNames"], count: outputCount, prefix: control.customFields["liveMatrixOutputPrefix"] ?? "Rx")

    return Group {
      Section("Per-Input Offsets") {
        ForEach(0..<inputCount, id: \.self) { i in
          perChipOffsetRow(
            label: inputNames[i], index: i,
            xKey: "liveMatrixInputOffsetX", yKey: "liveMatrixInputOffsetY",
            count: inputCount
          )
        }
        Button("Reset All to Default") {
          control.customFields.removeValue(forKey: "liveMatrixInputOffsetX")
          control.customFields.removeValue(forKey: "liveMatrixInputOffsetY")
        }
        .foregroundStyle(.red)
      }

      Section("Per-Output Offsets") {
        ForEach(0..<outputCount, id: \.self) { i in
          perChipOffsetRow(
            label: outputNames[i], index: i,
            xKey: "liveMatrixOutputOffsetX", yKey: "liveMatrixOutputOffsetY",
            count: outputCount
          )
        }
        Button("Reset All to Default") {
          control.customFields.removeValue(forKey: "liveMatrixOutputOffsetX")
          control.customFields.removeValue(forKey: "liveMatrixOutputOffsetY")
        }
        .foregroundStyle(.red)
      }
    }
  }

  /// Parsed long-press duration for icon toggle (seconds, 0.1 step, default 3.0).
  private func resolvedIconHoldDurationSec() -> Double {
    let raw = Double(control.customFields["iconHoldDurationSec"] ?? "") ?? 3.0
    let stepped = (raw * 10).rounded() / 10
    return min(max(stepped, 0.1), 60.0)
  }

  private var iconHoldDurationBinding: Binding<Double> {
    Binding(
      get: { resolvedIconHoldDurationSec() },
      set: {
        let v = min(max(($0 * 10).rounded() / 10, 0.1), 60.0)
        control.customFields["iconHoldDurationSec"] = String(format: "%.1f", v)
      }
    )
  }

  // MARK: - Icon Grid Picker

  private struct IconGridPicker: View {
    let title: String
    @Binding var selection: String
    let categories: [(name: String, symbols: [String])]

    @State private var showSheet = false
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 6)

    var body: some View {
      Button {
        showSheet = true
      } label: {
        HStack(spacing: 12) {
          Text(title)
            .foregroundStyle(.primary)
          Spacer()
          Image(systemName: selection)
            .font(.system(size: 22))
            .foregroundStyle(.primary)
            .frame(width: 32, height: 32)
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
      }
      .sheet(isPresented: $showSheet) {
        NavigationStack {
          ScrollView {
            ForEach(categories, id: \.name) { cat in
              VStack(alignment: .leading, spacing: 8) {
                Text(cat.name)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .padding(.horizontal, 16)
                  .padding(.top, 8)
                LazyVGrid(columns: columns, spacing: 10) {
                  ForEach(cat.symbols, id: \.self) { sym in
                    let isSelected = selection == sym
                    Button {
                      selection = sym
                      showSheet = false
                    } label: {
                      VStack(spacing: 4) {
                        Image(systemName: sym)
                          .font(.system(size: 24))
                          .frame(width: 44, height: 44)
                          .background(
                            isSelected
                              ? Color.accentColor.opacity(0.2)
                              : Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                          )
                          .overlay {
                            if isSelected {
                              RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.accentColor, lineWidth: 2)
                            }
                          }
                        Text(sym.components(separatedBy: ".").first ?? sym)
                          .font(.system(size: 9))
                          .foregroundStyle(.secondary)
                          .lineLimit(1)
                          .minimumScaleFactor(0.7)
                      }
                    }
                    .buttonStyle(.plain)
                  }
                }
                .padding(.horizontal, 12)
              }
            }
            Spacer(minLength: 24)
          }
          .navigationTitle(title)
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("取消") { showSheet = false }
            }
          }
        }
      }
    }
  }

  private var iconStyleSection: some View {
    Section("Icon Style") {
      IconGridPicker(
        title: "ON Icon",
        selection: Binding(
          get: { control.customFields["iconOn"] ?? "power.circle.fill" },
          set: { control.customFields["iconOn"] = $0 }
        ),
        categories: iconCategories
      )

      IconGridPicker(
        title: "OFF Icon",
        selection: Binding(
          get: { control.customFields["iconOff"] ?? "power.circle" },
          set: { control.customFields["iconOff"] = $0 }
        ),
        categories: iconCategories
      )

      Stepper(
        "Icon Size: \(Int(Double(control.customFields["iconSize"] ?? "") ?? 44))",
        value: Binding(
          get: { Double(control.customFields["iconSize"] ?? "") ?? 44 },
          set: { control.customFields["iconSize"] = String(Int($0)) }
        ),
        in: 20...100, step: 4
      )

      Stepper(
        "Long-press to toggle: \(String(format: "%.1f", resolvedIconHoldDurationSec()))s",
        value: iconHoldDurationBinding,
        in: 0.1...60.0,
        step: 0.1
      )

      Picker("ON Color", selection: Binding(
        get: { control.customFields["iconColorOn"] ?? "green" },
        set: { control.customFields["iconColorOn"] = $0 }
      )) {
        Text("Green").tag("green")
        Text("Blue").tag("blue")
        Text("Cyan").tag("cyan")
        Text("Orange").tag("orange")
        Text("Red").tag("red")
        Text("Yellow").tag("yellow")
        Text("White").tag("white")
      }

      Picker("OFF Color", selection: Binding(
        get: { control.customFields["iconColorOff"] ?? "gray" },
        set: { control.customFields["iconColorOff"] = $0 }
      )) {
        Text("Gray").tag("gray")
        Text("White").tag("white")
        Text("Black").tag("black")
        Text("Red").tag("red")
        Text("Blue").tag("blue")
        Text("Orange").tag("orange")
      }
    }
  }

  // MARK: Multi-Command Section (button only)

  private func extraCommandIDList() -> [UUID] {
    (control.customFields["extraCommandIDs"] ?? "")
      .split(separator: ",")
      .compactMap { UUID(uuidString: String($0).trimmingCharacters(in: .whitespaces)) }
  }

  private func saveExtraCommandIDs(_ ids: [UUID]) {
    control.customFields["extraCommandIDs"] = ids.map(\.uuidString).joined(separator: ",")
  }

  private var multiCommandSection: some View {
    let ids = extraCommandIDList()
    let commands = modelStore.draft.commands

    return Section {
      if commands.isEmpty {
        Label("Add commands in the Commands tab first", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
      } else {
        ForEach(Array(ids.enumerated()), id: \.offset) { idx, cmdID in
          HStack(spacing: 8) {
            Text("\(idx + 2)")
              .font(.system(.body, design: .monospaced))
              .foregroundStyle(.secondary)
              .frame(width: 24, alignment: .trailing)
            Picker("", selection: Binding(
              get: { cmdID },
              set: { newID in
                var updated = ids
                updated[idx] = newID
                saveExtraCommandIDs(updated)
              }
            )) {
              ForEach(commands) { cmd in Text(cmd.name).tag(cmd.id) }
            }
            .labelsHidden()
            Spacer()
            Button(role: .destructive) {
              var updated = ids
              updated.remove(at: idx)
              saveExtraCommandIDs(updated)
            } label: {
              Image(systemName: "minus.circle.fill")
                .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
          }
        }

        Button {
          let fallback = commands.first?.id ?? UUID()
          saveExtraCommandIDs(ids + [fallback])
        } label: {
          Label("Add Command", systemImage: "plus.circle")
        }

        Stepper(
          "Interval: \(Int(control.customFields["multiCmdIntervalMs"] ?? "") ?? 0) ms",
          value: Binding(
            get: { Double(Int(control.customFields["multiCmdIntervalMs"] ?? "") ?? 0) },
            set: { control.customFields["multiCmdIntervalMs"] = String(Int($0)) }
          ),
          in: 0...5000, step: 50
        )
      }
    } header: {
      HStack {
        Text("Multi-Command Sequence")
        Spacer()
        if !ids.isEmpty {
          Text("×\(ids.count + 1) commands")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    } footer: {
      Text("Commands run in order after the primary command. Interval = delay between each.")
        .font(.caption)
    }
  }

  private var offCommandSection: some View {
    Section {
      if !modelStore.draft.commands.isEmpty {
        Picker("OFF Command", selection: Binding(
          get: { UUID(uuidString: control.customFields["commandID_off"] ?? "") ?? UUID() },
          set: { control.customFields["commandID_off"] = $0.uuidString }
        )) {
          Text("— None —").tag(UUID())
          ForEach(modelStore.draft.commands) { cmd in
            Text(cmd.name).tag(cmd.id)
          }
        }
      } else {
        Label("Add commands in the Devices tab first", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
      }
    } header: {
      Text("OFF Command")
    } footer: {
      Text("The ON command is set in the Command section above. This OFF command is sent when switching off.")
        .font(.caption)
    }
  }

  // MARK: - Toggle / Icon Multi-Command Multi-Device Section

  private func toggleExtraCmdIDs(suffix: String) -> [UUID] {
    (control.customFields["extraCommandIDs_\(suffix)"] ?? "")
      .split(separator: ",")
      .compactMap { UUID(uuidString: String($0).trimmingCharacters(in: .whitespaces)) }
  }

  private func toggleExtraDevIDs(suffix: String) -> [UUID?] {
    (control.customFields["extraDeviceIDs_\(suffix)"] ?? "")
      .split(separator: ",")
      .map { UUID(uuidString: String($0).trimmingCharacters(in: .whitespaces)) }
  }

  private func saveToggleExtraCmds(_ ids: [UUID], suffix: String) {
    control.customFields["extraCommandIDs_\(suffix)"] = ids.map(\.uuidString).joined(separator: ",")
  }

  private func saveToggleExtraDevs(_ ids: [UUID?], suffix: String) {
    control.customFields["extraDeviceIDs_\(suffix)"] = ids.map { $0?.uuidString ?? "" }.joined(separator: ",")
  }

  private var toggleMultiCommandSection: some View {
    let commands = modelStore.draft.commands
    let devices = modelStore.draft.devices

    return Group {
      toggleExtraGroup(label: "ON", suffix: "on", commands: commands, devices: devices)
      toggleExtraGroup(label: "OFF", suffix: "off", commands: commands, devices: devices)

      Section {
        Stepper(
          "Interval: \(Int(control.customFields["multiCmdIntervalMs"] ?? "") ?? 0) ms",
          value: Binding(
            get: { Double(Int(control.customFields["multiCmdIntervalMs"] ?? "") ?? 0) },
            set: { control.customFields["multiCmdIntervalMs"] = String(Int($0)) }
          ),
          in: 0...5000, step: 50
        )
      } header: {
        Text("Multi-Command Interval")
      } footer: {
        Text("Delay between each extra command (applies to both ON and OFF sequences).")
          .font(.caption)
      }
    }
  }

  private func toggleExtraGroup(label: String, suffix: String, commands: [CommandItem], devices: [DeviceItem]) -> some View {
    let cmdIDs = toggleExtraCmdIDs(suffix: suffix)
    var devIDs = toggleExtraDevIDs(suffix: suffix)
    while devIDs.count < cmdIDs.count { devIDs.append(nil) }

    return Section {
      if commands.isEmpty {
        Label("Add commands in the Commands tab first", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
      } else {
        ForEach(Array(cmdIDs.enumerated()), id: \.offset) { idx, cmdID in
          VStack(spacing: 6) {
            HStack(spacing: 8) {
              Text("\(idx + 1)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
              Picker("Command", selection: Binding(
                get: { cmdID },
                set: { newID in
                  var updated = cmdIDs
                  updated[idx] = newID
                  saveToggleExtraCmds(updated, suffix: suffix)
                }
              )) {
                ForEach(commands) { cmd in Text(cmd.name).tag(cmd.id) }
              }
              .labelsHidden()
              Spacer()
              Button(role: .destructive) {
                var updatedCmds = cmdIDs
                updatedCmds.remove(at: idx)
                saveToggleExtraCmds(updatedCmds, suffix: suffix)
                var updatedDevs = devIDs
                if idx < updatedDevs.count { updatedDevs.remove(at: idx) }
                saveToggleExtraDevs(updatedDevs, suffix: suffix)
              } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
              }
              .buttonStyle(.plain)
            }

            Picker("Target Device", selection: Binding(
              get: { (idx < devIDs.count ? devIDs[idx] : nil) ?? UUID() },
              set: { newID in
                var updatedDevs = devIDs
                while updatedDevs.count <= idx { updatedDevs.append(nil) }
                updatedDevs[idx] = (newID == UUID()) ? nil : newID
                saveToggleExtraDevs(updatedDevs, suffix: suffix)
              }
            )) {
              Text("— Bound Device —").tag(UUID())
              ForEach(devices) { dev in Text(dev.name).tag(dev.id) }
            }
            .font(.caption)
          }
          .padding(.vertical, 2)
        }

        Button {
          let fallback = commands.first?.id ?? UUID()
          saveToggleExtraCmds(cmdIDs + [fallback], suffix: suffix)
          var updatedDevs = devIDs
          updatedDevs.append(nil)
          saveToggleExtraDevs(updatedDevs, suffix: suffix)
        } label: {
          Label("Add \(label) Command", systemImage: "plus.circle")
        }
      }
    } header: {
      HStack {
        Text("Extra \(label) Commands")
        Spacer()
        if !cmdIDs.isEmpty {
          Text("×\(cmdIDs.count)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    } footer: {
      Text("Extra commands sent after the primary \(label) command. Each can target a different device.")
        .font(.caption)
    }
  }

  private var behaviorSection: some View {
    Section("Behavior") {
      Picker("Mode", selection: $control.behavior) {
        Text("Momentary").tag(BehaviorKind.momentary)
        Text("Toggle").tag(BehaviorKind.toggle)
        Text("Radio").tag(BehaviorKind.radio)
      }
      .pickerStyle(.segmented)

      if control.behavior == .radio {
        TextField(
          "Radio group name (mutual exclusion)",
          text: Binding(
            get: { control.groupKey ?? "" },
            set: { control.groupKey = $0.isEmpty ? nil : $0 }
          )
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      }
    }
  }

  private var gridPositionSection: some View {
    // Step size 0.5 (half-cell); drag in the editor canvas for even finer sub-cell precision.
    let step = 0.5
    return Section("Size & Position") {
      Stepper("Column (X): \(fmtPlacement(control.placement.x))", value: $control.placement.x, in: 0.0...48.0, step: step)
      Stepper("Row (Y): \(fmtPlacement(control.placement.y))", value: $control.placement.y, in: 0.0...48.0, step: step)
      Stepper("Width: \(fmtPlacement(control.placement.w)) cells", value: $control.placement.w, in: 0.5...24.0, step: step)
      Stepper("Height: \(fmtPlacement(control.placement.h)) cells", value: $control.placement.h, in: 0.5...24.0, step: step)
    }
  }

  private var deviceSection: some View {
    Section {
      if modelStore.draft.devices.isEmpty {
        Label("Add a device in the Devices tab first", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
      } else {
        Picker("Device", selection: Binding(
          get: { control.binding?.deviceID ?? UUID() },
          set: { newID in
            if control.binding == nil {
              control.binding = ControlBinding(deviceID: newID, commandID: UUID())
            } else {
              control.binding?.deviceID = newID
            }
          }
        )) {
          ForEach(modelStore.draft.devices) { device in
            VStack(alignment: .leading) {
              Text(device.name)
              Text("\(device.host):\(device.port) - \(device.encoding.rawValue.uppercased())")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .tag(device.id)
          }
        }
      }
    } header: {
      Text("Bound Device")
    }
  }

  // MARK: Command Section (inline editor)

  private var commandSection: some View {
    Section {
      if !modelStore.draft.commands.isEmpty {
        Picker("Select Existing", selection: Binding(
          get: { control.binding?.commandID ?? UUID() },
          set: { newID in
            if control.binding == nil {
              control.binding = ControlBinding(deviceID: modelStore.draft.devices.first?.id ?? UUID(), commandID: newID)
            } else {
              control.binding?.commandID = newID
            }
            loadCommand(id: newID)
          }
        )) {
          ForEach(modelStore.draft.commands) { cmd in
            Text(cmd.name).tag(cmd.id)
          }
        }
      }

      TextField("Command Name", text: $commandName)

      Picker("Payload Type", selection: $commandPayloadKind) {
        Text("Text").tag(PayloadKind.text)
        Text("Hex").tag(PayloadKind.hex)
      }
      .pickerStyle(.segmented)

      TextField("Payload", text: $commandPayload, axis: .vertical)
        .lineLimit(2...5)
        .font(.system(.body, design: .monospaced))

      Text(payloadHint)
        .font(.caption)
        .foregroundStyle(.secondary)

      Picker("Line Ending", selection: $commandLineEnding) {
        ForEach(LineEnding.allCases) { ending in
          Text(ending.displayName).tag(ending)
        }
      }

      Stepper("Timeout: \(commandTimeoutMs) ms", value: $commandTimeoutMs, in: 100...10000, step: 100)
    } header: {
      Text("Command")
    }
  }

  @ViewBuilder
  private var customFieldsSection: some View {
    if !control.type.isMatrixChip && !control.customFields.isEmpty {
      Section("Custom Fields") {
        ForEach(Array(control.customFields.keys.sorted()), id: \.self) { key in
          LabeledContent(key) {
            Text(control.customFields[key] ?? "")
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  // MARK: Helpers

  private var payloadHint: String {
    switch commandPayloadKind {
    case .text:
      return "Example: MATRIX ROUTE 1 2\\r\\n"
    case .hex:
      return "Example: FF 01 03 0A 00 (hex bytes, space-separated)"
    }
  }

  private func loadBoundCommand() {
    guard let binding = control.binding else { return }
    loadCommand(id: binding.commandID)
  }

  private func loadCommand(id: UUID) {
    if let cmd = modelStore.draft.commands.first(where: { $0.id == id }) {
      boundCommandID = cmd.id
      commandName = cmd.name
      commandPayloadKind = cmd.payloadKind
      commandPayload = cmd.payload
      commandLineEnding = cmd.lineEnding
      commandTimeoutMs = cmd.timeoutMs
    } else {
      boundCommandID = nil
      commandName = ""
      commandPayloadKind = .text
      commandPayload = ""
      commandLineEnding = .crlf
      commandTimeoutMs = 1500
    }
  }

  private func buildUpdatedCommandIfNeeded() -> CommandItem? {
    var updatedCommand: CommandItem?
    if control.type != .label,
      !commandName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !commandPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      if let existingID = boundCommandID {
        var cmd = CommandItem(
          name: commandName, payloadKind: commandPayloadKind, payload: commandPayload,
          lineEnding: commandLineEnding, timeoutMs: commandTimeoutMs)
        cmd.id = existingID
        updatedCommand = cmd
        control.binding?.commandID = existingID
      } else {
        let cmd = CommandItem(
          name: commandName, payloadKind: commandPayloadKind, payload: commandPayload,
          lineEnding: commandLineEnding, timeoutMs: commandTimeoutMs)
        updatedCommand = cmd
        if control.binding != nil {
          control.binding?.commandID = cmd.id
        } else {
          control.binding = ControlBinding(
            deviceID: modelStore.draft.devices.first?.id ?? UUID(),
            commandID: cmd.id
          )
        }
      }
    }
    return updatedCommand
  }

  private func commitToDraft() {
    let updatedCommand = buildUpdatedCommandIfNeeded()
    onCommit(control, updatedCommand)
  }

  private func saveAll() {
    commitToDraft()
    dismiss()
  }

  private func switchToElement(_ id: UUID) {
    guard id != control.id else { return }
    guard onSelectOther != nil else { return }
    commitToDraft()
    onSelectOther?(id)
  }

  private var typeTag: some View {
    Text(control.type.rawValue.uppercased())
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(tagColor.opacity(0.18), in: Capsule())
      .foregroundStyle(tagColor)
  }

  private var tagColor: Color {
    switch control.type {
    case .button: return .blue
    case .slider: return .indigo
    case .toggle: return .teal
    case .label: return .gray
    case .icon: return .orange
    case .border: return .white
    case .matrix: return .purple
    case .liveMatrix: return .cyan
    case .volumeLevel: return .green
    case .matrixInput: return .blue
    case .matrixOutput: return .green
    case .liveMatrixInput: return .cyan
    case .liveMatrixOutput: return .mint
    }
  }

  // MARK: - Border Style Section

  private var borderStyleSection: some View {
    let colorMode = control.customFields["borderColorMode"] ?? "solid"
    return Section("Border Style") {
      HStack {
        Text("Thickness")
        Spacer()
        Stepper(
          "\(Int(Double(control.customFields["borderThickness"] ?? "") ?? 2)) pt",
          value: Binding(
            get: { Double(control.customFields["borderThickness"] ?? "") ?? 2 },
            set: { control.customFields["borderThickness"] = String(Int(max(1, $0))) }
          ),
          in: 1...30, step: 1
        )
      }
      HStack {
        Text("Corner Radius")
        Spacer()
        Stepper(
          "\(Int(Double(control.customFields["borderCornerRadius"] ?? "") ?? 12)) pt",
          value: Binding(
            get: { Double(control.customFields["borderCornerRadius"] ?? "") ?? 12 },
            set: { control.customFields["borderCornerRadius"] = String(Int(max(0, $0))) }
          ),
          in: 0...120, step: 2
        )
      }
      Picker("Color Mode", selection: Binding(
        get: { control.customFields["borderColorMode"] ?? "solid" },
        set: { control.customFields["borderColorMode"] = $0 }
      )) {
        Text("Solid").tag("solid")
        Text("Gradient").tag("gradient")
      }
      .pickerStyle(.segmented)

      if colorMode == "gradient" {
        ColorPicker("From", selection: Binding(
          get: { Color(hexString: control.customFields["borderGradientFrom"] ?? "#FFFFFF") },
          set: { control.customFields["borderGradientFrom"] = $0.toHexString() }
        ), supportsOpacity: false)
        ColorPicker("To", selection: Binding(
          get: { Color(hexString: control.customFields["borderGradientTo"] ?? "#0080FF") },
          set: { control.customFields["borderGradientTo"] = $0.toHexString() }
        ), supportsOpacity: false)
        let angle = Double(control.customFields["borderGradientAngle"] ?? "") ?? 0
        HStack {
          Text("Angle")
          Slider(
            value: Binding(
              get: { Double(control.customFields["borderGradientAngle"] ?? "") ?? 0 },
              set: { control.customFields["borderGradientAngle"] = String(Int($0)) }
            ),
            in: 0...360, step: 15
          )
          Text("\(Int(angle))°")
            .monospacedDigit()
            .frame(width: 44, alignment: .trailing)
        }
      } else {
        ColorPicker("Color", selection: Binding(
          get: { Color(hexString: control.customFields["borderColor"] ?? "#FFFFFF") },
          set: { control.customFields["borderColor"] = $0.toHexString() }
        ), supportsOpacity: false)
      }
    }
  }

  // MARK: - Chip Config Sections

  private var chipParentControl: ControlItem? {
    guard let parentID = control.customFields["parentControlID"],
          let uuid = UUID(uuidString: parentID) else { return nil }
    return modelStore.draft.controls.first(where: { $0.id == uuid })
  }

  private var chipBasicSection: some View {
    Section(L10n.lmChipSettings) {
      TextField(L10n.lmChipName, text: Binding(
        get: { control.customFields["chipName"] ?? control.title },
        set: { control.customFields["chipName"] = $0 }
      ))

      TextField(L10n.lmChipCommand, text: Binding(
        get: { control.customFields["chipCmd"] ?? "\(control.customFields["chipIndex"] ?? "0")" },
        set: { control.customFields["chipCmd"] = $0 }
      ))
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()

      LabeledContent(L10n.lmChipIndex) {
        Text(control.customFields["chipIndex"] ?? "0")
          .foregroundStyle(.secondary)
      }

      if let parent = chipParentControl {
        LabeledContent(L10n.lmChipParent) {
          Text(parent.title)
            .foregroundStyle(.secondary)
        }
        if onSelectOther != nil {
          Button(L10n.lmChipEditParent) {
            switchToElement(parent.id)
          }
        }
      } else if let parentID = control.customFields["parentControlID"] {
        let parentName = control.customFields["parentTitle"]
          ?? String(parentID.prefix(8)) + "..."
        LabeledContent(L10n.lmChipParent) {
          Text(parentName)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder
  private var chipCommandOverrideSection: some View {
    let isInput = control.type == .matrixInput || control.type == .liveMatrixInput
    Section(L10n.lmChipCommandOverride) {
      TextField(
        L10n.lmChipCommandTemplateHint,
        text: Binding(
          get: { control.customFields["chipCommandTemplate"] ?? "" },
          set: { control.customFields["chipCommandTemplate"] = $0.isEmpty ? nil : $0 }
        ),
        axis: .vertical
      )
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .lineLimit(2...4)

      if let tmpl = control.customFields["chipCommandTemplate"], !tmpl.isEmpty {
        let cmd = control.customFields["chipCmd"] ?? "0"
        let preview = isInput
          ? tmpl.replacingOccurrences(of: "{input}", with: cmd)
          : tmpl.replacingOccurrences(of: "{output}", with: cmd)
        LabeledContent(L10n.lmChipCommandPreview) {
          Text(preview)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
        }
      }
    }
  }

  @ViewBuilder
  private var chipInputStreamSection: some View {
    let ip = control.customFields["streamIP"] ?? ""
    let mac = control.customFields["streamDevID"] ?? ""
    Section {
      if discoveredEncoders.isEmpty {
        HStack {
          Text(L10n.lmEditorDevicelistEmpty)
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button {
            Task { await fetchDeviceList(for: .encoder) }
          } label: {
            if fetchingDeviceList {
              ProgressView().controlSize(.small)
            } else {
              Text(L10n.lmEditorFetchDevicelist)
                .font(.caption)
            }
          }
          .buttonStyle(.borderless)
          .disabled(fetchingDeviceList)
        }
        if let deviceListError {
          Text(deviceListError)
            .font(.caption)
            .foregroundStyle(.red)
        }
      } else {
        chipDiscoveredEncoderPicker
        Text(L10n.lmEditorDevicelistEncodersCount(discoveredEncoders.count))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      TextField(L10n.lmEditorMacPlaceholder, text: Binding(
        get: { control.customFields["streamDevID"] ?? "" },
        set: { control.customFields["streamDevID"] = $0 }
      ))
      .textInputAutocapitalization(.characters)
      .autocorrectionDisabled()
      .keyboardType(.asciiCapable)

      TextField(L10n.lmEditorDeviceIP, text: Binding(
        get: { control.customFields["streamIP"] ?? "" },
        set: { control.customFields["streamIP"] = $0 }
      ))
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .keyboardType(.numbersAndPunctuation)

      TextField(L10n.lmEditorStreamPort, text: Binding(
        get: { control.customFields["streamPort"] ?? "8080" },
        set: { control.customFields["streamPort"] = $0 }
      ))
      .keyboardType(.numberPad)

      if mac.trimmingCharacters(in: .whitespaces).isEmpty {
        Text(L10n.lmEditorMacEmptyWarning)
          .font(.caption)
          .foregroundStyle(.orange)
      }
      if isSuspiciousLiveMatrixIP(ip) {
        Text(L10n.lmEditorIpInvalidWarning)
          .font(.caption)
          .foregroundStyle(.orange)
      }
    } header: {
      Text(L10n.lmChipStreamDevice)
    } footer: {
      Text(L10n.lmEditorStreamFooter)
        .font(.caption)
    }
  }

  private var chipOutputPreviewSection: some View {
    Section {
      Text(L10n.lmEditorDisplayFooter)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var chipInheritedDeviceSection: some View {
    Section(L10n.lmChipInheritedDevice) {
      if let parent = chipParentControl,
         let devID = parent.binding?.deviceID,
         let dev = modelStore.draft.devices.first(where: { $0.id == devID }) {
        LabeledContent(dev.name) {
          Text("\(dev.host):\(dev.port)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else {
        Label(L10n.lmChipNoParentDevice, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
  }

  /// Inspector section for configuring which inputs are blocked from routing to this output chip.
  @ViewBuilder
  private var chipRouteRestrictionSection: some View {
    let outIdx = Int(control.customFields["chipIndex"] ?? "") ?? 0
    let isLive = control.type == .liveMatrixOutput
    let parentIDStr = control.customFields["parentControlID"] ?? ""

    if let parentIdx = modelStore.draft.controls.firstIndex(where: { $0.id.uuidString == parentIDStr }) {
      let parentCtrl = modelStore.draft.controls[parentIdx]
      let pfx = isLive ? "liveMatrix" : "matrix"
      let inputCountKey = isLive ? "liveMatrixInputCount" : "matrixInputCount"
      let inputCount = max(0, Int(parentCtrl.customFields[inputCountKey] ?? "") ?? 0)
      let inputNamesRaw = parentCtrl.customFields["\(pfx)InputNames"]
      let inputPrefix = parentCtrl.customFields["\(pfx)InputPrefix"] ?? "Tx"
      let inputNames = MatrixNamesHelper.parseNames(inputNamesRaw, count: inputCount, prefix: inputPrefix)
      let blockedSet = MatrixNamesHelper.blockedInputs(forOutput: outIdx, customFields: parentCtrl.customFields, isLive: isLive)

      Section {
        RouteBlacklistInline(
          blockedSet: blockedSet,
          inputCount: inputCount,
          inputNames: inputNames,
          onToggle: { inIdx, shouldBlock in
            var newBlocked = blockedSet
            if shouldBlock { newBlocked.insert(inIdx) } else { newBlocked.remove(inIdx) }
            let blockedKey = isLive ? "liveMatrixOutputBlockedInputs" : "matrixOutputBlockedInputs"
            let newJson = MatrixNamesHelper.setBlockedInputs(
              newBlocked, forOutput: outIdx,
              existing: parentCtrl.customFields, isLive: isLive
            )
            modelStore.draft.controls[parentIdx].customFields[blockedKey] = newJson
          }
        )
      } header: {
        Text(L10n.lmEditorRouteBlacklist)
      }
    }
  }

  // MARK: - Live Matrix Helpers

  private func isSuspiciousLiveMatrixIP(_ ip: String) -> Bool {
    let trimmed = ip.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return false }
    let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return true }
    return !parts.allSatisfy { part in
      guard let n = Int(part), n >= 0, n <= 255 else { return false }
      return true
    }
  }

  private func readLMJSONArray(_ key: String) -> [String] {
    guard let json = control.customFields[key],
          let data = json.data(using: .utf8),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
    else { return [] }
    return arr
  }

  private func writeLMJSONArray(_ key: String, _ arr: [String]) {
    guard let data = try? JSONSerialization.data(withJSONObject: arr),
          let s = String(data: data, encoding: .utf8)
    else { return }
    control.customFields[key] = s
  }

  private func resizeLMStringArray(key: String, toCount count: Int, fill: (Int) -> String) {
    var arr = readLMJSONArray(key)
    while arr.count < count { arr.append(fill(arr.count)) }
    if arr.count > count { arr = Array(arr.prefix(count)) }
    writeLMJSONArray(key, arr)
  }

  private func syncLiveMatrixChannelArrays(oldIn: Int, oldOut: Int, newIn: Int, newOut: Int) {
    let inPrefix = control.customFields["liveMatrixInputPrefix"] ?? "Tx"
    let outPrefix = control.customFields["liveMatrixOutputPrefix"] ?? "Rx"

    resizeLMStringArray(key: "liveMatrixInputNames", toCount: newIn) { i in "\(inPrefix)\(i + 1)" }
    resizeLMStringArray(key: "liveMatrixInputCmds", toCount: newIn) { i in "\(i + 1)" }
    resizeLMStringArray(key: "liveMatrixInputStreamIPs", toCount: newIn) { _ in "" }
    resizeLMStringArray(key: "liveMatrixInputStreamPorts", toCount: newIn) { _ in "8080" }
    resizeLMStringArray(key: "liveMatrixInputStreamDevIDs", toCount: newIn) { _ in "" }

    resizeLMStringArray(key: "liveMatrixOutputNames", toCount: newOut) { i in "\(outPrefix)\(i + 1)" }
    resizeLMStringArray(key: "liveMatrixOutputCmds", toCount: newOut) { i in "\(i + 1)" }
    resizeLMStringArray(key: "liveMatrixOutputStreamIPs", toCount: newOut) { _ in "" }
    resizeLMStringArray(key: "liveMatrixOutputStreamPorts", toCount: newOut) { _ in "8080" }
    resizeLMStringArray(key: "liveMatrixOutputStreamDevIDs", toCount: newOut) { _ in "" }

    let defChipW = CGFloat(Double(control.customFields["liveMatrixChipWidth"] ?? "") ?? 160)
    let defChipH = CGFloat(Double(control.customFields["liveMatrixChipHeight"] ?? "") ?? 120)
    let defOutW = CGFloat(Double(control.customFields["liveMatrixOutputChipWidth"] ?? "") ?? Double(defChipW))
    let defOutH = CGFloat(Double(control.customFields["liveMatrixOutputChipHeight"] ?? "") ?? Double(defChipH))

    resizeLMStringArray(key: "liveMatrixInputWidths", toCount: newIn) { _ in String(Int(defChipW)) }
    resizeLMStringArray(key: "liveMatrixInputHeights", toCount: newIn) { _ in String(Int(defChipH)) }
    resizeLMStringArray(key: "liveMatrixInputOffsetX", toCount: newIn) { _ in "0" }
    resizeLMStringArray(key: "liveMatrixInputOffsetY", toCount: newIn) { _ in "0" }
    resizeLMStringArray(key: "liveMatrixOutputWidths", toCount: newOut) { _ in String(Int(defOutW)) }
    resizeLMStringArray(key: "liveMatrixOutputHeights", toCount: newOut) { _ in String(Int(defOutH)) }
    resizeLMStringArray(key: "liveMatrixOutputOffsetX", toCount: newOut) { _ in "0" }
    resizeLMStringArray(key: "liveMatrixOutputOffsetY", toCount: newOut) { _ in "0" }

    if newOut < oldOut, let raw = control.customFields["liveMatrixOutputBlockedInputs"],
       let data = raw.data(using: .utf8),
       var dict = try? JSONSerialization.jsonObject(with: data) as? [String: [Int]] {
      for key in dict.keys {
        if let idx = Int(key), idx >= newOut { dict.removeValue(forKey: key) }
      }
      if let data = try? JSONSerialization.data(withJSONObject: dict),
         let str = String(data: data, encoding: .utf8) {
        control.customFields["liveMatrixOutputBlockedInputs"] = str
      }
    }
    _ = oldIn
    _ = oldOut
  }

  private func fetchAllInputDeviceInfo(inCount: Int) async {
    await MainActor.run { fetchingAllInputs = true }
    defer { Task { @MainActor in fetchingAllInputs = false } }
    for i in 0..<inCount {
      let cmdID = await MainActor.run {
        matrixCmdBinding(key: "liveMatrixInputCmds", index: i, count: inCount).wrappedValue
      }
      let trimmed = cmdID.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }
      await fetchDeviceInfo(cmdID: trimmed, isInput: true, index: i, count: inCount)
    }
  }

  // MARK: - Device Info Fetch

  /// Bound matrix controller for LiveMatrix parent or chip (via parent).
  private var matrixQueryDevice: DeviceItem? {
    let deviceID: UUID?
    if control.type == .liveMatrix {
      deviceID = control.binding?.deviceID
    } else if control.type == .liveMatrixInput {
      deviceID = chipParentControl?.binding?.deviceID
    } else {
      return nil
    }
    guard let deviceID else { return nil }
    return modelStore.draft.devices.first(where: { $0.id == deviceID })
  }

  private func fetchDeviceList(for role: MatrixDeviceRole) async {
    guard let device = matrixQueryDevice else {
      await MainActor.run {
        deviceListError = "未绑定设备 / No device bound"
      }
      return
    }
    guard device.keepAlive else {
      await MainActor.run {
        deviceListError = "设备需开启 Keep-Alive / Device must enable Keep-Alive"
      }
      return
    }

    await MainActor.run {
      fetchingDeviceList = true
      deviceListError = nil
    }
    defer { Task { @MainActor in fetchingDeviceList = false } }

    do {
      let line = try await MatrixDeviceQueryClient.query(
        transport: transport,
        device: device,
        payload: "config get devicelist"
      )
      if let devices = MatrixDeviceListParser.parse(line) {
        await MainActor.run {
          discoveredEncoders = devices.filter { $0.role == .encoder }
          discoveredDecoders = devices.filter { $0.role == .decoder }
          if role == .encoder, discoveredEncoders.isEmpty {
            deviceListError = "\(L10n.lmEditorDevicelistError) — no encoders"
          } else if role == .decoder, discoveredDecoders.isEmpty {
            deviceListError = "\(L10n.lmEditorDevicelistError) — no decoders"
          } else {
            deviceListError = nil
          }
        }
      } else {
        await MainActor.run {
          deviceListError = "\(L10n.lmEditorDevicelistError) — invalid response"
        }
      }
    } catch {
      await MainActor.run {
        deviceListError = "\(L10n.lmEditorDevicelistError): \(error.localizedDescription)"
      }
    }
  }

  /// Name defaults to device ID on pick; keeps user-edited names.
  private func shouldAutoFillChannelName(
    currentName: String, currentCmd: String, defaultName: String
  ) -> Bool {
    let trimmed = currentName.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return true }
    if trimmed == currentCmd { return true }
    if trimmed == defaultName { return true }
    return false
  }

  @ViewBuilder
  private func discoveredEncoderPicker(index: Int, inCount: Int) -> some View {
    let cmdBinding = matrixCmdBinding(key: "liveMatrixInputCmds", index: index, count: inCount)
    Picker(L10n.lmEditorPickDevice, selection: Binding(
      get: {
        let cmd = cmdBinding.wrappedValue
        return discoveredEncoders.contains(where: { $0.id == cmd }) ? cmd : ""
      },
      set: { newID in
        guard !newID.isEmpty,
              let picked = discoveredEncoders.first(where: { $0.id == newID }) else { return }
        applyDiscoveredEncoder(picked, toIndex: index, inCount: inCount)
      }
    )) {
      Text(L10n.lmEditorPickDeviceNone).tag("")
      ForEach(discoveredEncoders) { dev in
        Text("\(dev.id) · \(dev.ip)").tag(dev.id)
      }
    }
    .pickerStyle(.menu)
  }

  @ViewBuilder
  private func discoveredDecoderPicker(index: Int, outCount: Int, outPrefix: String) -> some View {
    let cmdBinding = matrixCmdBinding(key: "liveMatrixOutputCmds", index: index, count: outCount)
    Picker(L10n.lmEditorPickDevice, selection: Binding(
      get: {
        let cmd = cmdBinding.wrappedValue
        return discoveredDecoders.contains(where: { $0.id == cmd }) ? cmd : ""
      },
      set: { newID in
        guard !newID.isEmpty,
              let picked = discoveredDecoders.first(where: { $0.id == newID }) else { return }
        applyDiscoveredDecoder(picked, toIndex: index, outCount: outCount, outPrefix: outPrefix)
      }
    )) {
      Text(L10n.lmEditorPickDeviceNone).tag("")
      ForEach(discoveredDecoders) { dev in
        Text(dev.id).tag(dev.id)
      }
    }
    .pickerStyle(.menu)
  }

  private var chipDiscoveredEncoderPicker: some View {
    Picker(L10n.lmEditorPickDevice, selection: Binding(
      get: {
        let cmd = control.customFields["chipCmd"] ?? ""
        return discoveredEncoders.contains(where: { $0.id == cmd }) ? cmd : ""
      },
      set: { newID in
        guard !newID.isEmpty,
              let picked = discoveredEncoders.first(where: { $0.id == newID }) else { return }
        applyDiscoveredDeviceToChip(picked)
      }
    )) {
      Text(L10n.lmEditorPickDeviceNone).tag("")
      ForEach(discoveredEncoders) { dev in
        Text("\(dev.id) · \(dev.ip)").tag(dev.id)
      }
    }
    .pickerStyle(.menu)
  }

  private func applyDiscoveredEncoder(
    _ device: MatrixDiscoveredDevice, toIndex index: Int, inCount: Int
  ) {
    let nameKey = "liveMatrixInputNames"
    let inPrefix = control.customFields["liveMatrixInputPrefix"] ?? "Tx"
    let names = MatrixNamesHelper.parseNames(
      control.customFields[nameKey], count: inCount, prefix: inPrefix)
    let currentName = index >= 0 && index < names.count ? names[index] : ""
    let currentCmd = matrixCmdBinding(key: "liveMatrixInputCmds", index: index, count: inCount).wrappedValue
    let defaultName = "\(inPrefix)\(index + 1)"

    if shouldAutoFillChannelName(
      currentName: currentName, currentCmd: currentCmd, defaultName: defaultName
    ) {
      updateLMJSONArray(key: nameKey, index: index, value: device.id, count: inCount)
    }
    updateLMJSONArray(key: "liveMatrixInputCmds", index: index, value: device.id, count: inCount)
    updateLMJSONArray(key: "liveMatrixInputStreamDevIDs", index: index, value: device.mac, count: inCount)
    updateLMJSONArray(key: "liveMatrixInputStreamIPs", index: index, value: device.ip, count: inCount)
    fetchError["in_\(index)"] = nil
  }

  private func applyDiscoveredDecoder(
    _ device: MatrixDiscoveredDevice, toIndex index: Int, outCount: Int, outPrefix: String
  ) {
    let nameKey = "liveMatrixOutputNames"
    let names = MatrixNamesHelper.parseNames(
      control.customFields[nameKey], count: outCount, prefix: outPrefix)
    let currentName = index >= 0 && index < names.count ? names[index] : ""
    let currentCmd = matrixCmdBinding(key: "liveMatrixOutputCmds", index: index, count: outCount).wrappedValue
    let defaultName = "\(outPrefix)\(index + 1)"

    if shouldAutoFillChannelName(
      currentName: currentName, currentCmd: currentCmd, defaultName: defaultName
    ) {
      updateLMJSONArray(key: nameKey, index: index, value: device.id, count: outCount)
    }
    updateLMJSONArray(key: "liveMatrixOutputCmds", index: index, value: device.id, count: outCount)
  }

  private func applyDiscoveredDeviceToChip(_ device: MatrixDiscoveredDevice) {
    let parent = chipParentControl
    let chipIndex = Int(control.customFields["chipIndex"] ?? "") ?? 0
    let inPrefix = parent?.customFields["liveMatrixInputPrefix"] ?? "Tx"
    let defaultName = "\(inPrefix)\(chipIndex + 1)"
    let currentName = control.customFields["chipName"] ?? control.title
    let currentCmd = control.customFields["chipCmd"] ?? ""
    if shouldAutoFillChannelName(
      currentName: currentName, currentCmd: currentCmd, defaultName: defaultName
    ) {
      control.customFields["chipName"] = device.id
      control.title = device.id
    }
    control.customFields["chipCmd"] = device.id
    control.customFields["streamDevID"] = device.mac
    control.customFields["streamIP"] = device.ip
  }

  /// Sends `config get device info {cmdID}` to the bound device, then parses
  /// the JSON response and auto-fills the MAC and IP fields for the given row.
  private func fetchDeviceInfo(cmdID: String, isInput: Bool, index: Int, count: Int) async {
    let fetchKey = "\(isInput ? "in" : "out")_\(index)"
    let ipKey   = isInput ? "liveMatrixInputStreamIPs"    : "liveMatrixOutputStreamIPs"
    let macKey  = isInput ? "liveMatrixInputStreamDevIDs" : "liveMatrixOutputStreamDevIDs"
    let portKey = isInput ? "liveMatrixInputStreamPorts"  : "liveMatrixOutputStreamPorts"

    guard let device = matrixQueryDevice else {
      await MainActor.run { fetchError[fetchKey] = "未绑定设备 / No device bound" }
      return
    }
    guard device.keepAlive else {
      await MainActor.run {
        fetchError[fetchKey] = "设备需开启 Keep-Alive / Device must enable Keep-Alive"
      }
      return
    }

    _ = await MainActor.run { fetchingInfo.insert(fetchKey) }
    defer { Task { @MainActor in fetchingInfo.remove(fetchKey) } }

    do {
      let line = try await MatrixDeviceQueryClient.query(
        transport: transport,
        device: device,
        payload: "config get device info \(cmdID)"
      )
      if let info = MatrixDeviceListParser.parseDeviceInfo(line) {
        await MainActor.run {
          updateLMJSONArray(key: macKey, index: index, value: info.mac, count: count)
          updateLMJSONArray(key: ipKey,  index: index, value: info.ip,  count: count)
          if let streamPort = info.port, !streamPort.isEmpty {
            updateLMJSONArray(key: portKey, index: index, value: streamPort, count: count)
          }
          fetchError[fetchKey] = nil
        }
      } else {
        await MainActor.run {
          fetchError[fetchKey] = "超时未收到响应 / Timeout — no response for \"\(cmdID)\""
        }
      }
    } catch {
      await MainActor.run {
        fetchError[fetchKey] = "发送失败 / Send failed: \(error.localizedDescription)"
      }
    }
  }

  /// Writes a single value into a JSON-encoded string array stored in `control.customFields`.
  private func updateLMJSONArray(key: String, index: Int, value: String, count: Int) {
    var arr: [String]
    if let json = control.customFields[key],
       let data = json.data(using: .utf8),
       let existing = try? JSONSerialization.jsonObject(with: data) as? [String] {
      arr = existing
    } else {
      arr = Array(repeating: "", count: count)
    }
    while arr.count <= index { arr.append("") }
    arr[index] = value
    if let data = try? JSONSerialization.data(withJSONObject: arr),
       let s = String(data: data, encoding: .utf8) {
      control.customFields[key] = s
    }
  }
}

/// Inline blacklist button + sheet (no Section wrapper).
private struct RouteBlacklistInline: View {
  let blockedSet: Set<Int>
  let inputCount: Int
  let inputNames: [String]
  let onToggle: (Int, Bool) -> Void

  @State private var showSheet = false

  private var summaryText: String {
    if blockedSet.isEmpty { return "无限制" }
    if blockedSet.count == inputCount { return "全部屏蔽" }
    let names = blockedSet.sorted().map { inputNames[safe: $0] ?? "Tx\($0 + 1)" }
    let joined = names.prefix(3).joined(separator: "、")
    return blockedSet.count > 3 ? "\(joined) 等\(blockedSet.count)个" : joined
  }

  var body: some View {
    Button {
      showSheet = true
    } label: {
      HStack {
        Label(L10n.lmEditorRouteBlacklist, systemImage: "lock.slash")
          .font(.caption)
          .foregroundStyle(.primary)
        Spacer()
        Text(summaryText)
          .font(.caption2)
          .foregroundStyle(blockedSet.isEmpty ? Color.secondary : Color.red)
          .lineLimit(1)
        Image(systemName: "chevron.right")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .buttonStyle(.plain)
    .sheet(isPresented: $showSheet) {
      RouteBlacklistSheet(
        blockedSet: blockedSet,
        inputCount: inputCount,
        inputNames: inputNames,
        onToggle: onToggle,
        onDismiss: { showSheet = false }
      )
    }
  }
}

/// Compact single-row blacklist control that expands into a sheet for editing.
private struct RouteBlacklistRow: View {
  let blockedSet: Set<Int>
  let inputCount: Int
  let inputNames: [String]
  let onToggle: (Int, Bool) -> Void

  var body: some View {
    Section {
      RouteBlacklistInline(
        blockedSet: blockedSet,
        inputCount: inputCount,
        inputNames: inputNames,
        onToggle: onToggle
      )
    }
  }
}

private struct RouteBlacklistSheet: View {
  let blockedSet: Set<Int>
  let inputCount: Int
  let inputNames: [String]
  let onToggle: (Int, Bool) -> Void
  let onDismiss: () -> Void

  var body: some View {
    NavigationStack {
      List {
        if inputCount == 0 {
          Text("请先在父级矩阵控件中设置输入数量")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Section {
            ForEach(0..<inputCount, id: \.self) { inIdx in
              let isBlocked = blockedSet.contains(inIdx)
              Button {
                onToggle(inIdx, !isBlocked)
              } label: {
                HStack {
                  Image(systemName: "video.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                  Text(inputNames[safe: inIdx] ?? "Tx\(inIdx + 1)")
                    .foregroundStyle(.primary)
                  Spacer()
                  if isBlocked {
                    Image(systemName: "checkmark")
                      .foregroundStyle(.red)
                      .fontWeight(.semibold)
                  }
                }
              }
            }
          } header: {
            Text("已勾选的信号源将无法切换到此显示器")
          }
        }
      }
      .navigationTitle(L10n.lmEditorRouteBlacklist)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") { onDismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
