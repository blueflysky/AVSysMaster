import SwiftUI

struct UIStyleSettingsView: View {
  @EnvironmentObject private var modelStore: UnifiedModelStore
  @State private var alertMessage: AlertMessage?

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        themeGrid
          .padding(20)
      }
    }
    .alert(item: $alertMessage) { item in
      Alert(title: Text(item.message))
    }
  }

  private var header: some View {
    HStack {
      Text("UI Style")
        .font(.headline)
      Spacer()
      Text("Current: \(modelStore.draft.styles.uiTheme.displayName)")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private var themeGrid: some View {
    let columns = [
      GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 16),
    ]
    return LazyVGrid(columns: columns, spacing: 16) {
      ForEach(UIStyleTheme.allCases) { theme in
        themeCard(theme)
      }
    }
  }

  private func themeCard(_ theme: UIStyleTheme) -> some View {
    let isSelected = modelStore.draft.styles.uiTheme == theme
    let colors = ThemeColors.forTheme(theme)

    return Button {
      modelStore.draft.styles.uiTheme = theme
      Task {
        try? await modelStore.saveDraft()
        let _ = modelStore.publishDraft()
      }
    } label: {
      VStack(spacing: 0) {
        ZStack {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(colors.background)
          if colors.hasGradient {
            colors.gradient.ignoresSafeArea()
              .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          }
          if colors.hasOverlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(colors.overlay)
          }

          HStack(spacing: 8) {
            mockButton(text: "Btn", colors: colors)
            mockButton(text: "ON", colors: colors, active: true)
            VStack(spacing: 3) {
              Circle()
                .fill(colors.iconColor)
                .frame(width: 18, height: 18)
              Text("Icon")
                .font(.system(size: 7))
                .foregroundStyle(colors.textColor)
            }
          }
          .padding(12)
        }
        .frame(height: 90)

        HStack {
          Text(theme.displayName)
            .font(.subheadline.weight(.medium))
          Spacer()
          if isSelected {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.blue)
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color(uiColor: .secondarySystemGroupedBackground))
      )
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2.5)
      }
    }
    .buttonStyle(.plain)
  }

  private func mockButton(text: String, colors: ThemeColors, active: Bool = false) -> some View {
    Text(text)
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(colors.textColor)
      .frame(width: 40, height: 28)
      .background(
        active ? colors.activeButtonBg : colors.idleButtonBg,
        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(active ? colors.activeBorder : colors.idleBorder, lineWidth: 1)
      }
  }
}

struct ThemeColors {
  let background: Color
  let hasGradient: Bool
  let gradient: LinearGradient
  let hasOverlay: Bool
  let overlay: Color
  let textColor: Color
  let idleButtonBg: Color
  let activeButtonBg: Color
  let idleBorder: Color
  let activeBorder: Color
  let iconColor: Color
  let toggleBg: Color

  // iOS system color constants
  private static let sysBlue    = Color(red: 0.0,  green: 0.48, blue: 1.0)    // #007AFF
  private static let sysGreen   = Color(red: 0.2,  green: 0.78, blue: 0.35)   // #34C759
  private static let sysIndigo  = Color(red: 0.35, green: 0.34, blue: 0.84)   // #5856D6
  private static let sysOrange  = Color(red: 1.0,  green: 0.58, blue: 0.0)    // #FF9500
  private static let sysPink    = Color(red: 1.0,  green: 0.18, blue: 0.33)   // #FF2D55
  private static let sysPurple  = Color(red: 0.69, green: 0.32, blue: 0.87)   // #AF52DE
  private static let sysTeal    = Color(red: 0.19, green: 0.69, blue: 0.78)   // #30B0C7
  private static let sysCyan    = Color(red: 0.20, green: 0.68, blue: 0.90)   // #32ADE6
  private static let sysMint    = Color(red: 0.0,  green: 0.78, blue: 0.75)   // #00C7BE
  private static let sysYellow  = Color(red: 1.0,  green: 0.8,  blue: 0.0)    // #FFCC00
  private static let sysRed     = Color(red: 1.0,  green: 0.23, blue: 0.19)   // #FF3B30

  private static let labelDark  = Color.white
  private static let labelLight = Color(red: 0.11, green: 0.11, blue: 0.12)   // iOS UIColor.label

  private static let darkBg1    = Color(red: 0.11, green: 0.11, blue: 0.12)   // #1C1C1E
  private static let darkBg2    = Color(red: 0.17, green: 0.17, blue: 0.18)   // #2C2C2E

  static func forTheme(_ theme: UIStyleTheme) -> ThemeColors {
    switch theme {

    // MARK: – Dark (iOS Dark Mode)
    case .dark:
      return ThemeColors(
        background: darkBg1,
        hasGradient: true,
        gradient: LinearGradient(colors: [sysBlue.opacity(0.06), sysIndigo.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing),
        hasOverlay: false,
        overlay: .clear,
        textColor: labelDark,
        idleButtonBg: darkBg2,
        activeButtonBg: sysBlue.opacity(0.22),
        idleBorder: .white.opacity(0.08),
        activeBorder: sysBlue.opacity(0.40),
        iconColor: sysGreen,
        toggleBg: sysGreen
      )

    // MARK: – Light (iOS Light Mode)
    case .light:
      return ThemeColors(
        background: .white,
        hasGradient: false,
        gradient: LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom),
        hasOverlay: false,
        overlay: .clear,
        textColor: labelLight,
        idleButtonBg: Color(red: 0.95, green: 0.95, blue: 0.97),
        activeButtonBg: sysBlue.opacity(0.10),
        idleBorder: Color(red: 0.78, green: 0.78, blue: 0.8).opacity(0.30),
        activeBorder: sysBlue.opacity(0.40),
        iconColor: sysBlue,
        toggleBg: sysGreen
      )

    // MARK: – Glass (frosted translucency)
    case .glass:
      return ThemeColors(
        background: Color(red: 0.10, green: 0.10, blue: 0.12),
        hasGradient: true,
        gradient: LinearGradient(colors: [sysPurple.opacity(0.06), sysCyan.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing),
        hasOverlay: false,
        overlay: .clear,
        textColor: .white.opacity(0.92),
        idleButtonBg: .white.opacity(0.06),
        activeButtonBg: .white.opacity(0.14),
        idleBorder: .white.opacity(0.10),
        activeBorder: sysCyan.opacity(0.40),
        iconColor: sysCyan,
        toggleBg: sysCyan
      )

    // MARK: – Midnight (deep indigo-black)
    case .midnight:
      return ThemeColors(
        background: Color(red: 0.04, green: 0.04, blue: 0.10),
        hasGradient: true,
        gradient: LinearGradient(colors: [sysIndigo.opacity(0.08), sysPurple.opacity(0.04)], startPoint: .top, endPoint: .bottom),
        hasOverlay: false,
        overlay: .clear,
        textColor: labelDark,
        idleButtonBg: Color(red: 0.10, green: 0.10, blue: 0.19),
        activeButtonBg: sysIndigo.opacity(0.28),
        idleBorder: sysIndigo.opacity(0.15),
        activeBorder: sysPurple.opacity(0.45),
        iconColor: sysPurple,
        toggleBg: sysIndigo
      )

    // MARK: – Ocean (deep blue-teal)
    case .ocean:
      return ThemeColors(
        background: Color(red: 0.03, green: 0.08, blue: 0.15),
        hasGradient: true,
        gradient: LinearGradient(colors: [sysBlue.opacity(0.08), sysTeal.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing),
        hasOverlay: false,
        overlay: .clear,
        textColor: labelDark,
        idleButtonBg: Color(red: 0.06, green: 0.13, blue: 0.22),
        activeButtonBg: sysTeal.opacity(0.28),
        idleBorder: sysTeal.opacity(0.12),
        activeBorder: sysTeal.opacity(0.45),
        iconColor: sysTeal,
        toggleBg: sysTeal
      )

    // MARK: – Warm Gray (warm dark surface)
    case .warmGray:
      return ThemeColors(
        background: Color(red: 0.13, green: 0.12, blue: 0.11),
        hasGradient: true,
        gradient: LinearGradient(colors: [sysOrange.opacity(0.04), Color.brown.opacity(0.02)], startPoint: .top, endPoint: .bottom),
        hasOverlay: false,
        overlay: .clear,
        textColor: labelDark,
        idleButtonBg: Color(red: 0.20, green: 0.19, blue: 0.17),
        activeButtonBg: sysOrange.opacity(0.25),
        idleBorder: sysOrange.opacity(0.10),
        activeBorder: sysOrange.opacity(0.40),
        iconColor: sysOrange,
        toggleBg: sysOrange
      )

    // MARK: – Sky Blue (light blue tinted)
    case .lightBlue:
      return ThemeColors(
        background: Color(red: 0.95, green: 0.97, blue: 1.0),
        hasGradient: true,
        gradient: LinearGradient(colors: [sysBlue.opacity(0.04), sysCyan.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing),
        hasOverlay: false,
        overlay: .clear,
        textColor: labelLight,
        idleButtonBg: .white,
        activeButtonBg: sysBlue.opacity(0.10),
        idleBorder: sysBlue.opacity(0.10),
        activeBorder: sysBlue.opacity(0.35),
        iconColor: sysBlue,
        toggleBg: sysBlue
      )

    // MARK: – Mint Fresh (light mint tinted)
    case .lightMint:
      return ThemeColors(
        background: Color(red: 0.94, green: 0.99, blue: 0.97),
        hasGradient: true,
        gradient: LinearGradient(colors: [sysMint.opacity(0.05), sysGreen.opacity(0.02)], startPoint: .top, endPoint: .bottom),
        hasOverlay: false,
        overlay: .clear,
        textColor: labelLight,
        idleButtonBg: .white,
        activeButtonBg: sysMint.opacity(0.12),
        idleBorder: sysMint.opacity(0.14),
        activeBorder: sysMint.opacity(0.40),
        iconColor: sysMint,
        toggleBg: sysMint
      )

    // MARK: – Rose (light pink tinted)
    case .lightPink:
      return ThemeColors(
        background: Color(red: 1.0, green: 0.95, blue: 0.96),
        hasGradient: true,
        gradient: LinearGradient(colors: [sysPink.opacity(0.04), sysOrange.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing),
        hasOverlay: false,
        overlay: .clear,
        textColor: labelLight,
        idleButtonBg: .white,
        activeButtonBg: sysPink.opacity(0.10),
        idleBorder: sysPink.opacity(0.12),
        activeBorder: sysPink.opacity(0.35),
        iconColor: sysPink,
        toggleBg: sysPink
      )

    // MARK: – Lavender (light purple tinted)
    case .lightLavender:
      return ThemeColors(
        background: Color(red: 0.96, green: 0.94, blue: 1.0),
        hasGradient: true,
        gradient: LinearGradient(colors: [sysPurple.opacity(0.04), sysIndigo.opacity(0.02)], startPoint: .top, endPoint: .bottom),
        hasOverlay: false,
        overlay: .clear,
        textColor: labelLight,
        idleButtonBg: .white,
        activeButtonBg: sysPurple.opacity(0.10),
        idleBorder: sysPurple.opacity(0.10),
        activeBorder: sysPurple.opacity(0.35),
        iconColor: sysPurple,
        toggleBg: sysPurple
      )

    // MARK: – Sand (warm beige tinted)
    case .lightSand:
      return ThemeColors(
        background: Color(red: 0.98, green: 0.96, blue: 0.93),
        hasGradient: true,
        gradient: LinearGradient(colors: [sysOrange.opacity(0.04), sysYellow.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing),
        hasOverlay: false,
        overlay: .clear,
        textColor: labelLight,
        idleButtonBg: .white,
        activeButtonBg: sysOrange.opacity(0.10),
        idleBorder: sysOrange.opacity(0.10),
        activeBorder: sysOrange.opacity(0.35),
        iconColor: sysOrange,
        toggleBg: sysOrange
      )

    // MARK: – Peach (warm peach tinted)
    case .lightPeach:
      let peach = Color(red: 0.96, green: 0.52, blue: 0.37)
      return ThemeColors(
        background: Color(red: 1.0, green: 0.95, blue: 0.92),
        hasGradient: true,
        gradient: LinearGradient(colors: [peach.opacity(0.05), sysPink.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing),
        hasOverlay: false,
        overlay: .clear,
        textColor: labelLight,
        idleButtonBg: .white,
        activeButtonBg: peach.opacity(0.12),
        idleBorder: peach.opacity(0.12),
        activeBorder: peach.opacity(0.40),
        iconColor: peach,
        toggleBg: peach
      )

    // MARK: – Lemon (warm yellow tinted)
    case .lightLemon:
      let lemon = Color(red: 0.90, green: 0.72, blue: 0.0)
      return ThemeColors(
        background: Color(red: 1.0, green: 0.99, blue: 0.93),
        hasGradient: true,
        gradient: LinearGradient(colors: [sysYellow.opacity(0.05), sysGreen.opacity(0.02)], startPoint: .top, endPoint: .bottom),
        hasOverlay: false,
        overlay: .clear,
        textColor: labelLight,
        idleButtonBg: .white,
        activeButtonBg: sysYellow.opacity(0.14),
        idleBorder: lemon.opacity(0.14),
        activeBorder: lemon.opacity(0.40),
        iconColor: lemon,
        toggleBg: sysYellow
      )

    // MARK: – Sage (earthy green tinted)
    case .lightSage:
      let sage = Color(red: 0.42, green: 0.60, blue: 0.42)
      return ThemeColors(
        background: Color(red: 0.94, green: 0.96, blue: 0.93),
        hasGradient: true,
        gradient: LinearGradient(colors: [sage.opacity(0.05), sysGreen.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing),
        hasOverlay: false,
        overlay: .clear,
        textColor: labelLight,
        idleButtonBg: .white,
        activeButtonBg: sage.opacity(0.12),
        idleBorder: sage.opacity(0.12),
        activeBorder: sysGreen.opacity(0.40),
        iconColor: sysGreen,
        toggleBg: sysGreen
      )

    // MARK: – Coral (warm coral tinted)
    case .lightCoral:
      let coral = Color(red: 1.0, green: 0.38, blue: 0.30)
      return ThemeColors(
        background: Color(red: 1.0, green: 0.96, blue: 0.94),
        hasGradient: true,
        gradient: LinearGradient(colors: [coral.opacity(0.04), sysOrange.opacity(0.02)], startPoint: .top, endPoint: .bottom),
        hasOverlay: false,
        overlay: .clear,
        textColor: labelLight,
        idleButtonBg: .white,
        activeButtonBg: coral.opacity(0.10),
        idleBorder: coral.opacity(0.10),
        activeBorder: coral.opacity(0.38),
        iconColor: coral,
        toggleBg: coral
      )

    // MARK: – Ice (cool blue-white)
    case .lightIce:
      let ice = Color(red: 0.35, green: 0.68, blue: 0.94)
      return ThemeColors(
        background: Color(red: 0.95, green: 0.97, blue: 1.0),
        hasGradient: true,
        gradient: LinearGradient(colors: [ice.opacity(0.05), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom),
        hasOverlay: false,
        overlay: .clear,
        textColor: labelLight,
        idleButtonBg: .white,
        activeButtonBg: ice.opacity(0.14),
        idleBorder: ice.opacity(0.12),
        activeBorder: ice.opacity(0.40),
        iconColor: ice,
        toggleBg: sysBlue
      )

    // MARK: – Pure White (iOS standard white)
    case .pureWhite:
      return ThemeColors(
        background: .white,
        hasGradient: false,
        gradient: LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom),
        hasOverlay: false,
        overlay: .clear,
        textColor: labelLight,
        idleButtonBg: Color(red: 0.95, green: 0.95, blue: 0.97),
        activeButtonBg: sysBlue.opacity(0.12),
        idleBorder: Color(red: 0.78, green: 0.78, blue: 0.8).opacity(0.36),
        activeBorder: sysBlue.opacity(0.45),
        iconColor: sysBlue,
        toggleBg: sysGreen
      )
    }
  }
}
