import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Edge-Care visual language ("Edi" avatar proposal, concept 01).
// Mulberry #830051 · Magenta #d0006f · Warm white #f7f2eb, graphite text, light gray canvas.

extension Color {
    init(edgeHex hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    init(edgeLight light: UInt32, dark: UInt32) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
        #elseif canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
        #else
        self.init(edgeHex: light)
        #endif
    }
}

public enum EdgeCareStyle {
    public static let mulberry = Color(edgeHex: 0x830051)
    public static let magenta = Color(edgeHex: 0xD0006F)
    public static let warmWhite = Color(edgeHex: 0xF7F2EB)
    /// Brand-colored text and controls that stay readable in either appearance.
    public static let accent = Color(edgeLight: 0x830051, dark: 0xF0A9D1)
    /// Headline and body text.
    public static let graphite = Color(edgeLight: 0x2B2630, dark: 0xF4EFF5)
    /// Very light gray page canvas.
    public static let canvas = Color(edgeLight: 0xF6F5F7, dark: 0x17131A)
    /// Cards, inputs and device "paper".
    public static let card = Color(edgeLight: 0xFFFFFF, dark: 0x221D26)
    /// Option rows and quiet surfaces.
    public static let surface = Color(edgeLight: 0xF3F1F4, dark: 0x2C2530)
    /// Soft mulberry tint for selection, pills and the background glow.
    public static let blush = Color(edgeLight: 0xFBEAF2, dark: 0x392638)
    public static let hairline = Color(edgeLight: 0xE6E1E8, dark: 0x4A3C4C)
    static let faceInk = Color(edgeHex: 0x3A1F24)
    static let mulberryDeep = Color(edgeHex: 0x67003F)
    static let mulberryLight = Color(edgeHex: 0xA3086A)
}

// MARK: - Edi

/// Edi, the Edge-Care guide: an open doorway with a face. Drawn as vector art so it stays
/// crisp from sidebar-icon size up to the kiosk hero. Decorative only; hidden from VoiceOver.
public struct EdiView: View {
    public enum Pose: Sendable { case welcome, listening, nextStep }
    let pose: Pose
    let animated: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(pose: Pose = .listening, animated: Bool = true) { self.pose = pose; self.animated = animated }

    public var body: some View {
        let moving = animated && !reduceMotion && pose == .welcome
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { timeline in
            let wave = moving ? sin(timeline.date.timeIntervalSinceReferenceDate * 2.4) : 0
            Canvas { context, size in EdiView.draw(in: &context, size: size, pose: pose, wave: wave) }
        }
        .aspectRatio(146.0 / 132.0, contentMode: .fit)
        .accessibilityHidden(true)
    }

    /// The 146×132 viewport includes the entire waving arm at every animation
    /// angle; the original 130-wide viewport visibly clipped its fingertips.
    static func draw(in context: inout GraphicsContext, size: CGSize, pose: Pose, wave: Double) {
        let scale = min(size.width / 146, size.height / 132)
        context.translateBy(x: (size.width - 146 * scale) / 2, y: (size.height - 132 * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 15, y: 4)

        // Contact shadow.
        context.fill(Path(ellipseIn: CGRect(x: 4, y: 117, width: 92, height: 9)), with: .color(EdgeCareStyle.mulberry.opacity(0.10)))

        // Body: one thick round-capped stroke along the arch centre line, so the feet come out rounded
        // and the open doorway stays as true negative space.
        var arch = Path()
        arch.move(to: CGPoint(x: 22, y: 103))
        arch.addLine(to: CGPoint(x: 22, y: 45))
        arch.addCurve(to: CGPoint(x: 50, y: 17), control1: CGPoint(x: 22, y: 29.5), control2: CGPoint(x: 34.5, y: 17))
        arch.addCurve(to: CGPoint(x: 78, y: 45), control1: CGPoint(x: 65.5, y: 17), control2: CGPoint(x: 78, y: 29.5))
        arch.addLine(to: CGPoint(x: 78, y: 103))
        let bodyStroke = StrokeStyle(lineWidth: 34, lineCap: .round, lineJoin: .round)
        // Magenta rim peeking out along the upper-left edge.
        context.stroke(arch.applying(CGAffineTransform(translationX: -1.4, y: -1.2)), with: .color(EdgeCareStyle.magenta), style: bodyStroke)
        context.stroke(arch.applying(CGAffineTransform(translationX: 0.6, y: 0.5)),
                       with: .linearGradient(Gradient(colors: [EdgeCareStyle.mulberryLight, EdgeCareStyle.mulberry, EdgeCareStyle.mulberryDeep]),
                                             startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 100, y: 120)),
                       style: bodyStroke)

        // Arms.
        let rightAngle: Double
        switch pose {
        case .welcome: rightAngle = -2.4 + 0.2 * wave
        case .listening: rightAngle = -0.22
        case .nextStep: rightAngle = -1.45
        }
        drawArm(in: &context, pivot: CGPoint(x: 4, y: 54), angle: 0.22)
        drawArm(in: &context, pivot: CGPoint(x: 96, y: 54), angle: rightAngle)

        // Warm white face dome in the upper arch.
        var face = Path()
        face.move(to: CGPoint(x: 30, y: 31))
        face.addCurve(to: CGPoint(x: 50, y: 9), control1: CGPoint(x: 30, y: 18), control2: CGPoint(x: 39, y: 9))
        face.addCurve(to: CGPoint(x: 70, y: 31), control1: CGPoint(x: 61, y: 9), control2: CGPoint(x: 70, y: 18))
        face.addQuadCurve(to: CGPoint(x: 30, y: 31), control: CGPoint(x: 50, y: 34))
        context.fill(face, with: .color(EdgeCareStyle.warmWhite))

        // Eyes and a small smile.
        context.fill(Path(ellipseIn: CGRect(x: 41.3, y: 17.2, width: 3.4, height: 4.6)), with: .color(EdgeCareStyle.faceInk))
        context.fill(Path(ellipseIn: CGRect(x: 55.3, y: 17.2, width: 3.4, height: 4.6)), with: .color(EdgeCareStyle.faceInk))
        var smile = Path()
        smile.move(to: CGPoint(x: 45.6, y: 25))
        smile.addQuadCurve(to: CGPoint(x: 54.4, y: 25), control: CGPoint(x: 50, y: 29))
        context.stroke(smile, with: .color(EdgeCareStyle.faceInk), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }

    /// A rounded arm hanging from `pivot`; `angle` rotates it (0 = straight down, positive swings toward -x).
    private static func drawArm(in context: inout GraphicsContext, pivot: CGPoint, angle: Double) {
        let arm = Path(roundedRect: CGRect(x: -7, y: -3, width: 14, height: 30), cornerRadius: 7)
            .applying(CGAffineTransform(translationX: pivot.x, y: pivot.y).rotated(by: angle))
        context.fill(arm, with: .color(EdgeCareStyle.mulberry))
        context.stroke(arm, with: .color(EdgeCareStyle.magenta.opacity(0.55)), lineWidth: 1.2)
    }
}

/// Edi + "Edge-Care" in mulberry, as on the kiosk, doctor and CRM studies.
public struct EdgeCareWordmark: View {
    let size: CGFloat
    let showsEdi: Bool
    public init(size: CGFloat = 22, showsEdi: Bool = true) { self.size = size; self.showsEdi = showsEdi }
    public var body: some View {
        HStack(spacing: size * 0.4) {
            if showsEdi { EdiView(pose: .listening, animated: false).frame(width: size * 1.7, height: size * 1.7) }
            Text("Edge-Care").font(.system(size: size, weight: .bold)).foregroundStyle(EdgeCareStyle.accent)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Edge-Care")
    }
}

/// Light gray canvas with a soft mulberry glow in the trailing corner.
public struct EdgeCareBackground: View {
    public init() {}
    public var body: some View {
        ZStack {
            EdgeCareStyle.canvas
            RadialGradient(colors: [EdgeCareStyle.blush, EdgeCareStyle.canvas.opacity(0)],
                           center: .bottomTrailing, startRadius: 0, endRadius: 620)
        }
        .ignoresSafeArea()
    }
}

/// Small status capsule, e.g. "Open" on a referral row.
public struct EdgeCareStatusPill: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(EdgeCareStyle.accent)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(EdgeCareStyle.blush))
    }
}

// MARK: - Buttons

/// Filled mulberry capsule; the one main action on a screen.
public struct EdgeCarePrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { StyledBody(configuration: configuration) }
    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        var body: some View {
            configuration.label
                .font(.headline).foregroundStyle(.white).multilineTextAlignment(.center)
                .padding(.horizontal, 24).padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Capsule().fill(EdgeCareStyle.mulberry))
                .contentShape(Capsule())
                .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// Mulberry outline capsule for secondary choices (e.g. a language that isn't selected).
public struct EdgeCareSecondaryButtonStyle: ButtonStyle {
    let fullWidth: Bool
    public init(fullWidth: Bool = false) { self.fullWidth = fullWidth }
    public func makeBody(configuration: Configuration) -> some View { StyledBody(configuration: configuration, fullWidth: fullWidth) }
    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        let fullWidth: Bool
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            let color = configuration.role == .destructive ? Color.red : EdgeCareStyle.accent
            configuration.label
                .font(.body.weight(.semibold)).foregroundStyle(color).multilineTextAlignment(.center)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 48)
                .background(Capsule().fill(configuration.isPressed ? EdgeCareStyle.blush : EdgeCareStyle.card))
                .overlay(Capsule().strokeBorder(color.opacity(0.85), lineWidth: 1.5))
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

/// Rounded option row ("A health concern ›"). Selected rows take the blush tint and a mulberry edge.
public struct EdgeCareRowButtonStyle: ButtonStyle {
    let selected: Bool
    public init(selected: Bool = false) { self.selected = selected }
    public func makeBody(configuration: Configuration) -> some View { StyledBody(configuration: configuration, selected: selected) }
    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            configuration.label
                .font(.body.weight(.medium)).foregroundStyle(EdgeCareStyle.graphite).multilineTextAlignment(.leading)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .background(shape.fill(selected || configuration.isPressed ? EdgeCareStyle.blush : EdgeCareStyle.surface))
                .overlay(shape.strokeBorder(selected ? EdgeCareStyle.accent.opacity(0.6) : .clear, lineWidth: 1.5))
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.5)
        }
    }
}

/// Language choice on the welcome screen: the selected language is a filled mulberry capsule,
/// the others are outlined (English / Suomi on the kiosk study).
struct LanguageChipStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(selected ? Color.white : EdgeCareStyle.accent)
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .background(Capsule().fill(selected ? EdgeCareStyle.magenta : (configuration.isPressed ? EdgeCareStyle.blush : EdgeCareStyle.card)))
            .overlay(Capsule().strokeBorder(selected ? Color.clear : EdgeCareStyle.accent.opacity(0.85), lineWidth: 1.5))
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == EdgeCarePrimaryButtonStyle {
    public static var edgeCarePrimary: EdgeCarePrimaryButtonStyle { EdgeCarePrimaryButtonStyle() }
}
extension ButtonStyle where Self == EdgeCareSecondaryButtonStyle {
    public static var edgeCareSecondary: EdgeCareSecondaryButtonStyle { EdgeCareSecondaryButtonStyle() }
}
extension ButtonStyle where Self == EdgeCareRowButtonStyle {
    public static var edgeCareRow: EdgeCareRowButtonStyle { EdgeCareRowButtonStyle() }
}

/// Toggle rendered as an option row with a trailing check circle.
public struct EdgeCareCheckRowToggleStyle: ToggleStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 12)
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(configuration.isOn ? EdgeCareStyle.accent : Color.secondary)
            }
        }
        .buttonStyle(EdgeCareRowButtonStyle(selected: configuration.isOn))
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

extension ToggleStyle where Self == EdgeCareCheckRowToggleStyle {
    public static var edgeCareCheckRow: EdgeCareCheckRowToggleStyle { EdgeCareCheckRowToggleStyle() }
}

// MARK: - Surfaces

extension View {
    /// White rounded card with a hairline edge.
    public func edgeCareCard(padding: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(EdgeCareStyle.card))
            .overlay(shape.strokeBorder(EdgeCareStyle.hairline, lineWidth: 1))
    }

    /// Hides the default grouped background of a List/Form and shows the Edge-Care canvas instead.
    public func edgeCareListBackground() -> some View {
        self.scrollContentBackground(.hidden).background(EdgeCareBackground())
    }
}
