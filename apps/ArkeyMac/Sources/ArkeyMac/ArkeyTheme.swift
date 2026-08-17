import SwiftUI

/// Shared visual language for the desktop command surface.
///
/// The palette intentionally stays neutral and quiet so semantic keyboard
/// lighting remains the strongest color in the interface.
enum ArkeyTheme {
    static let window = Color(red: 0.105, green: 0.105, blue: 0.105)
    static let sidebar = Color(red: 0.075, green: 0.075, blue: 0.075)
    static let canvas = Color(red: 0.125, green: 0.125, blue: 0.125)
    static let surface = Color.white.opacity(0.052)
    static let surfaceRaised = Color.white.opacity(0.075)
    static let surfaceHover = Color.white.opacity(0.095)
    static let surfacePressed = Color.white.opacity(0.125)
    static let stroke = Color.white.opacity(0.085)
    static let strokeStrong = Color.white.opacity(0.15)
    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.60)
    static let textTertiary = Color.white.opacity(0.48)
    static let accent = Color(red: 0.118, green: 0.745, blue: 0.525)
    static let accentSoft = accent.opacity(0.14)
    static let warning = Color(red: 0.96, green: 0.64, blue: 0.24)
    static let danger = Color(red: 0.94, green: 0.30, blue: 0.34)

    static let sidebarWidth: CGFloat = 248
    static let drawerWidth: CGFloat = 340
    static let panelRadius: CGFloat = 14
    static let controlRadius: CGFloat = 9

    static func interactionAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.08)
            : .easeOut(duration: 0.12)
    }
}

enum ArkeyButtonTone {
    case neutral
    case selected
    case accent
    case danger
}

struct ArkeyIconButtonStyle: ButtonStyle {
    var tone: ArkeyButtonTone = .neutral
    var size: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        ArkeyIconButtonBody(
            configuration: configuration,
            tone: tone,
            size: size
        )
    }
}

/// Blue is reserved for a published application update. It is intentionally
/// not reused for keyboard actions, so it remains recognisable at a glance.
struct ArkeyUpdateButtonStyle: ButtonStyle {
    let isAvailable: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(isAvailable ? Color.white : ArkeyTheme.textPrimary)
            .frame(width: 30, height: 30)
            .background(isAvailable ? Color.blue.opacity(configuration.isPressed ? 0.68 : 0.90) : Color.clear, in: Circle())
            .overlay(Circle().stroke(isAvailable ? Color.blue.opacity(0.9) : ArkeyTheme.stroke, lineWidth: 0.75))
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct ArkeyIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tone: ArkeyButtonTone
    let size: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(background, in: RoundedRectangle(cornerRadius: ArkeyTheme.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ArkeyTheme.controlRadius, style: .continuous)
                    .strokeBorder(border, lineWidth: isFocused ? 1.5 : 0.75)
            }
            .contentShape(RoundedRectangle(cornerRadius: ArkeyTheme.controlRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .onHover { isHovered = isEnabled && $0 }
            .animation(ArkeyTheme.interactionAnimation(reduceMotion: reduceMotion), value: isHovered)
            .animation(ArkeyTheme.interactionAnimation(reduceMotion: reduceMotion), value: isFocused)
            .animation(ArkeyTheme.interactionAnimation(reduceMotion: reduceMotion), value: configuration.isPressed)
    }

    private var background: Color {
        if configuration.isPressed {
            return tone == .accent ? ArkeyTheme.accent.opacity(0.68) : ArkeyTheme.surfacePressed
        }
        switch tone {
        case .accent:
            return isHovered ? ArkeyTheme.accent.opacity(0.90) : ArkeyTheme.accent.opacity(0.78)
        case .selected:
            return isHovered ? Color.white.opacity(0.15) : Color.white.opacity(0.11)
        case .danger:
            return isHovered ? ArkeyTheme.danger.opacity(0.20) : Color.clear
        case .neutral:
            return isHovered ? ArkeyTheme.surfaceHover : Color.clear
        }
    }

    private var border: Color {
        if isFocused { return ArkeyTheme.accent.opacity(0.78) }
        switch tone {
        case .accent: return ArkeyTheme.accent.opacity(0.85)
        case .selected: return ArkeyTheme.strokeStrong
        case .danger: return isHovered ? ArkeyTheme.danger.opacity(0.42) : .clear
        case .neutral: return isHovered ? ArkeyTheme.stroke : .clear
        }
    }

    private var foreground: Color {
        if !isEnabled { return ArkeyTheme.textTertiary }
        if tone == .accent { return Color.black.opacity(0.82) }
        return tone == .danger && isHovered ? ArkeyTheme.danger : ArkeyTheme.textPrimary
    }
}

struct ArkeyControlButtonStyle: ButtonStyle {
    var tone: ArkeyButtonTone = .neutral
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        ArkeyControlButtonBody(
            configuration: configuration,
            tone: tone,
            compact: compact
        )
    }
}

private struct ArkeyControlButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tone: ArkeyButtonTone
    let compact: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 10 : 13)
            .frame(height: compact ? 28 : 32)
            .background(background, in: RoundedRectangle(cornerRadius: ArkeyTheme.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ArkeyTheme.controlRadius, style: .continuous)
                    .strokeBorder(border, lineWidth: isFocused ? 1.5 : 0.75)
            }
            .contentShape(RoundedRectangle(cornerRadius: ArkeyTheme.controlRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .onHover { isHovered = isEnabled && $0 }
            .animation(ArkeyTheme.interactionAnimation(reduceMotion: reduceMotion), value: isHovered)
            .animation(ArkeyTheme.interactionAnimation(reduceMotion: reduceMotion), value: isFocused)
            .animation(ArkeyTheme.interactionAnimation(reduceMotion: reduceMotion), value: configuration.isPressed)
    }

    private var background: Color {
        if configuration.isPressed {
            return tone == .accent ? ArkeyTheme.accent.opacity(0.72) : ArkeyTheme.surfacePressed
        }
        switch tone {
        case .accent:
            return isHovered ? ArkeyTheme.accent.opacity(0.94) : ArkeyTheme.accent.opacity(0.82)
        case .selected:
            return isHovered ? Color.white.opacity(0.15) : Color.white.opacity(0.11)
        case .danger:
            return isHovered ? ArkeyTheme.danger.opacity(0.18) : ArkeyTheme.surface
        case .neutral:
            return isHovered ? ArkeyTheme.surfaceHover : ArkeyTheme.surface
        }
    }

    private var border: Color {
        if isFocused { return ArkeyTheme.accent.opacity(0.78) }
        switch tone {
        case .accent: return ArkeyTheme.accent.opacity(0.9)
        case .selected: return ArkeyTheme.strokeStrong
        case .danger: return isHovered ? ArkeyTheme.danger.opacity(0.45) : ArkeyTheme.stroke
        case .neutral: return isHovered ? ArkeyTheme.strokeStrong : ArkeyTheme.stroke
        }
    }

    private var foreground: Color {
        if !isEnabled { return ArkeyTheme.textTertiary }
        if tone == .accent { return Color.black.opacity(0.82) }
        return tone == .danger ? (isHovered ? ArkeyTheme.danger : ArkeyTheme.textSecondary) : ArkeyTheme.textPrimary
    }
}

struct ArkeySidebarButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        ArkeySidebarButtonBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct ArkeySidebarButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        isFocused ? ArkeyTheme.accent.opacity(0.78) : (isSelected ? ArkeyTheme.stroke : .clear),
                        lineWidth: isFocused ? 1.5 : 0.75
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .onHover { isHovered = $0 }
            .animation(ArkeyTheme.interactionAnimation(reduceMotion: reduceMotion), value: isHovered)
            .animation(ArkeyTheme.interactionAnimation(reduceMotion: reduceMotion), value: isFocused)
            .animation(ArkeyTheme.interactionAnimation(reduceMotion: reduceMotion), value: configuration.isPressed)
    }

    private var background: Color {
        if configuration.isPressed { return ArkeyTheme.surfacePressed }
        if isSelected { return Color.white.opacity(isHovered ? 0.115 : 0.085) }
        return isHovered ? ArkeyTheme.surfaceHover : .clear
    }
}

struct ArkeyTileButtonStyle: ButtonStyle {
    var isSelected = false
    var accent: Color = ArkeyTheme.accent

    func makeBody(configuration: Configuration) -> some View {
        ArkeyTileButtonBody(
            configuration: configuration,
            isSelected: isSelected,
            accent: accent
        )
    }
}

private struct ArkeyTileButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    let accent: Color

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .background(background, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(border, lineWidth: isFocused ? 1.5 : (isSelected ? 1 : 0.75))
            }
            .shadow(color: isSelected ? accent.opacity(0.10) : .clear, radius: 10, y: 4)
            .scaleEffect(configuration.isPressed ? 0.96 : (isHovered && isEnabled ? 1.025 : 1))
            .offset(y: isHovered && isEnabled && !reduceMotion ? -1 : 0)
            .opacity(isEnabled ? 1 : 0.38)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .onHover { isHovered = isEnabled && $0 }
            .animation(ArkeyTheme.interactionAnimation(reduceMotion: reduceMotion), value: isHovered)
            .animation(ArkeyTheme.interactionAnimation(reduceMotion: reduceMotion), value: isFocused)
            .animation(ArkeyTheme.interactionAnimation(reduceMotion: reduceMotion), value: configuration.isPressed)
    }

    private var background: Color {
        if configuration.isPressed { return ArkeyTheme.surfacePressed }
        if isSelected { return accent.opacity(isHovered ? 0.19 : 0.14) }
        return isHovered ? ArkeyTheme.surfaceHover : ArkeyTheme.surface
    }

    private var border: Color {
        if isFocused { return ArkeyTheme.accent.opacity(0.78) }
        if isSelected { return accent.opacity(0.58) }
        return isHovered ? ArkeyTheme.strokeStrong : ArkeyTheme.stroke
    }
}

private struct ArkeyPanelModifier: ViewModifier {
    let radius: CGFloat
    let raised: Bool

    func body(content: Content) -> some View {
        content
            .background(
                raised ? ArkeyTheme.surfaceRaised : ArkeyTheme.surface,
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(ArkeyTheme.stroke, lineWidth: 0.75)
            }
    }
}

extension View {
    func arkeyPanel(radius: CGFloat = ArkeyTheme.panelRadius, raised: Bool = false) -> some View {
        modifier(ArkeyPanelModifier(radius: radius, raised: raised))
    }
}
