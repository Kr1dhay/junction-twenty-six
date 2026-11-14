import SwiftUI
import EdgeCareCore

public struct SignaturePad: View {
    @Binding var strokes: [[SignaturePoint]]
    let language: String
    @State private var current: [SignaturePoint] = []
    public init(strokes: Binding<[[SignaturePoint]]>, language: String = "en") {
        _strokes = strokes; self.language = language
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
            .background(.background)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.secondary, lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard current.count + strokes.reduce(0, { $0 + $1.count }) < 4000 else { return }
                    current.append(SignaturePoint(x: Double(value.location.x), y: Double(value.location.y), time: Date().timeIntervalSince1970))
                }
                .onEnded { _ in if !current.isEmpty { strokes.append(current) }; current = [] })
            .accessibilityLabel(Copy.text("signature", language))
            .accessibilityHint(Copy.text("signatureHint", language))
            .accessibilityAddTraits(.allowsDirectInteraction)
            Button(Copy.text("clear", language), role: .destructive) { strokes = []; current = [] }.frame(minHeight: 44)
        }
    }
}

struct PINField: View {
    let title: String
    @Binding var value: String
    var body: some View {
        SecureField(title, text: $value)
            #if os(iOS)
            .keyboardType(.numberPad)
            .textContentType(.newPassword)
            #endif
            .textFieldStyle(.roundedBorder)
            .frame(minHeight: 48)
            .onChange(of: value) { _, new in value = String(new.filter { $0.isASCII && $0.isNumber }.prefix(4)) }
            .accessibilityLabel(title)
    }
}
