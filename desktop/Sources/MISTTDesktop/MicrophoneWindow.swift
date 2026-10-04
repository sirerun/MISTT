import AppKit
import SwiftUI

struct MicrophoneWindow: View {
    @ObservedObject var controller: BridgeController
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    @FocusState private var micFocused: Bool

    private var presentation: RelayPresentation { controller.presentation }
    private var microphoneColor: Color {
        if presentation.isMuted { return .primary }
        if accessibilityContrast == .increased {
            return colorScheme == .dark
                ? Color(red: 1.0, green: 0.82, blue: 0.48)
                : Color(red: 0.35, green: 0.20, blue: 0.0)
        }
        return colorScheme == .dark
            ? Color(red: 0.95, green: 0.72, blue: 0.30)
            : Color(red: 0.48, green: 0.29, blue: 0.02)
    }

    var body: some View {
        VStack(spacing: 12) {
            Button(action: controller.toggleMute) {
                ZStack {
                    Circle()
                        .fill(Color.clear)
                    MicLogo(isMuted: presentation.isMuted,
                            foreground: microphoneColor)
                        .frame(width: 96, height: 96)
                    Circle()
                        .strokeBorder(micFocused ? Color.accentColor : .clear,
                                      lineWidth: accessibilityContrast == .increased ? 3 : 2)
                }
                .frame(width: 144, height: 144)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .focused($micFocused)
            .disabled(!presentation.isInteractive)
            .help(presentation.accessibleReason ?? presentation.buttonLabel)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.buttonLabel)
            .accessibilityValue(presentation.buttonValue)
            .accessibilityHint("Press Space or Return to change both microphone and selected app audio.")
            .accessibilityAddTraits(.updatesFrequently)

            Text(presentation.stateTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .accessibilityHidden(true)

            Text(presentation.clientCount)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityHidden(true)
        }
        .padding(24)
        .frame(width: 260, height: 260)
        .accessibilityAddTraits(.updatesFrequently)
        .modifier(FloatingSurface())
        .background(FloatingWindow())
    }
}

/// SwiftUI Canvas rendering of the selected logo-3 paths at any display scale.
/// Source SVGs are bundled beside the app; the paths here follow their 100×100 viewBox.
private struct MicLogo: View {
    let isMuted: Bool
    let foreground: Color

    var body: some View {
        Canvas { context, size in
            var drawing = context
            drawing.scaleBy(x: size.width / 100, y: size.height / 100)

            let microphone = Path(roundedRect: CGRect(x: 36, y: 12, width: 28, height: 48),
                                  cornerSize: CGSize(width: 14, height: 14))
            drawing.fill(microphone, with: .color(foreground))

            let grille = Path { path in
                path.addRoundedRect(in: CGRect(x: 43, y: 29, width: 14, height: 4),
                                    cornerSize: CGSize(width: 2, height: 2))
                path.addRoundedRect(in: CGRect(x: 43, y: 42, width: 14, height: 4),
                                    cornerSize: CGSize(width: 2, height: 2))
            }
            var knockout = drawing
            knockout.blendMode = .destinationOut
            knockout.fill(grille, with: .color(.white))

            var cradle = Path()
            cradle.move(to: CGPoint(x: 25, y: 47))
            cradle.addLine(to: CGPoint(x: 25, y: 51))
            cradle.addCurve(to: CGPoint(x: 50, y: 76),
                            control1: CGPoint(x: 25, y: 65),
                            control2: CGPoint(x: 36, y: 76))
            cradle.addCurve(to: CGPoint(x: 75, y: 51),
                            control1: CGPoint(x: 64, y: 76),
                            control2: CGPoint(x: 75, y: 65))
            cradle.addLine(to: CGPoint(x: 75, y: 47))
            drawing.stroke(cradle, with: .color(foreground), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))

            var stand = Path()
            stand.move(to: CGPoint(x: 50, y: 76))
            stand.addLine(to: CGPoint(x: 50, y: 88))
            drawing.stroke(stand, with: .color(foreground), style: StrokeStyle(lineWidth: 8, lineCap: .round))

            var base = Path()
            base.move(to: CGPoint(x: 37, y: 89))
            base.addLine(to: CGPoint(x: 63, y: 89))
            drawing.stroke(base, with: .color(foreground), style: StrokeStyle(lineWidth: 8, lineCap: .round))

            if isMuted {
                var slash = Path()
                slash.move(to: CGPoint(x: 22, y: 20))
                slash.addLine(to: CGPoint(x: 78, y: 80))
                drawing.stroke(slash, with: .color(foreground), style: StrokeStyle(lineWidth: 7, lineCap: .round))
            }
        }
        .accessibilityHidden(true)
    }
}
