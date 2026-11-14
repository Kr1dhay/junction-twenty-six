import SwiftUI
import EdgeCareCore

public struct SignaturePad: View {
    @Binding var strokes: [[SignaturePoint]]
    let language: String
    @State private var current: [SignaturePoint] = []
    @Environment(\.edgeCareCompactLayout) private var compact
    public init(strokes: Binding<[[SignaturePoint]]>, language: String = "en") {
        _strokes = strokes; self.language = language
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            Text(Copy.text("signatureHint", language)).font(.subheadline).foregroundStyle(.secondary)
            Canvas { context, _ in
                for stroke in strokes + [current] where !stroke.isEmpty {
                    var path = Path()
                    path.move(to: CGPoint(x: stroke[0].x, y: stroke[0].y))
                    for point in stroke.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
                    context.stroke(path, with: .color(EdgeCareStyle.mulberry), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(height: 190)
            .background(EdgeCareStyle.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(EdgeCareStyle.hairline, lineWidth: 1.5))
            .overlay(alignment: .bottomLeading) {
                Image(systemName: "pencil.line").font(.title3).foregroundStyle(EdgeCareStyle.mulberry.opacity(0.35))
                    .padding(14).allowsHitTesting(false).accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard current.count + strokes.reduce(0, { $0 + $1.count }) < 4000 else { return }
                    current.append(SignaturePoint(x: Double(value.location.x), y: Double(value.location.y), time: Date().timeIntervalSince1970))
                }
                .onEnded { _ in if !current.isEmpty { strokes.append(current) }; current = [] })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Copy.text("signature", language))
            .accessibilityIdentifier("signatureCanvas")
            .accessibilityHint(Copy.text("signatureHint", language))
            .accessibilityAddTraits(.allowsDirectInteraction)
            Button(Copy.text("clear", language), role: .destructive) { strokes = []; current = [] }.frame(minHeight: 44)
        }
    }
}

/// Four-digit code entry drawn as four cells. A hidden SecureField does the real input, so the
/// number pad, paste and VoiceOver keep working; the cells only show progress as dots.
struct PINField: View {
    let title: String
    @Binding var value: String
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.edgeCareCompactLayout) private var compact
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(EdgeCareStyle.graphite)
            ZStack(alignment: .leading) {
                SecureField(title, text: $value)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    .textContentType(.newPassword)
                    #endif
                    .focused($focused)
                    .foregroundStyle(.clear).tint(.clear)
                    .frame(width: 1, height: 1).opacity(0.02)
                    .onChange(of: value) { _, new in value = String(new.filter { $0.isASCII && $0.isNumber }.prefix(4)) }
                    .accessibilityLabel(title)
                HStack(spacing: 12) {
                    ForEach(0..<4, id: \.self) { index in
                        let active = focused && index == min(value.count, 3)
                        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                        shape.fill(EdgeCareStyle.card)
                            .overlay(shape.strokeBorder(active ? EdgeCareStyle.magenta : EdgeCareStyle.hairline, lineWidth: active ? 2 : 1.5))
                            .overlay { if index < value.count { Circle().fill(EdgeCareStyle.graphite).frame(width: 12, height: 12) } }
                            .frame(width: compact ? 48 : 54, height: compact ? 52 : 60)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if isEnabled { focused = true } }
                .accessibilityHidden(true)
            }
            .opacity(isEnabled ? 1 : 0.5)
        }
    }
}

/// Verification stays side by side on the landscape kiosk, and stacks at
/// accessibility sizes or on narrower screens.
struct ReferralVerificationFields: View {
    let title: String
    @Binding var passcode: String
    @Binding var strokes: [[SignaturePoint]]
    let language: String
    @Environment(\.edgeCareCompactLayout) private var compact
    var body: some View {
        let layout = compact ? AnyLayout(HStackLayout(alignment: .top, spacing: 32)) :
            AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
        layout {
            PINField(title: title, value: $passcode).frame(maxWidth: .infinity, alignment: .leading)
            SignaturePad(strokes: $strokes, language: language).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
