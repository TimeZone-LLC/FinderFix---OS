import AppKit
import SwiftUI

enum ArcaneTokens {
    static let pagePadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 18
    static let controlSpacing: CGFloat = 12
    static let cardRadius: CGFloat = 14
    static let controlRadius: CGFloat = 9

    static let accent: Color = adaptiveColor(
        light: NSColor(srgbRed: 0.21, green: 0.27, blue: 0.78, alpha: 1),
        dark: NSColor(srgbRed: 0.65, green: 0.70, blue: 1.00, alpha: 1)
    )
    static let positive: Color = adaptiveColor(
        light: NSColor(srgbRed: 0.08, green: 0.48, blue: 0.29, alpha: 1),
        dark: NSColor(srgbRed: 0.37, green: 0.84, blue: 0.60, alpha: 1)
    )
    static let warning: Color = adaptiveColor(
        light: NSColor(srgbRed: 0.60, green: 0.33, blue: 0.00, alpha: 1),
        dark: NSColor(srgbRed: 1.00, green: 0.71, blue: 0.36, alpha: 1)
    )
    static let destructive: Color = adaptiveColor(
        light: NSColor(srgbRed: 0.70, green: 0.13, blue: 0.21, alpha: 1),
        dark: NSColor(srgbRed: 1.00, green: 0.48, blue: 0.53, alpha: 1)
    )
    static let information: Color = adaptiveColor(
        light: NSColor(srgbRed: 0.09, green: 0.42, blue: 0.66, alpha: 1),
        dark: NSColor(srgbRed: 0.45, green: 0.73, blue: 0.95, alpha: 1)
    )
    static let primaryButtonForeground: Color = adaptiveColor(
        light: NSColor.white,
        dark: NSColor(srgbRed: 0.05, green: 0.07, blue: 0.16, alpha: 1)
    )
    static let disabledControlFill: Color = adaptiveColor(
        light: NSColor(srgbRed: 0.85, green: 0.86, blue: 0.90, alpha: 1),
        dark: NSColor(srgbRed: 0.23, green: 0.24, blue: 0.28, alpha: 1)
    )
    static let disabledControlForeground: Color = adaptiveColor(
        light: NSColor(srgbRed: 0.36, green: 0.37, blue: 0.41, alpha: 1),
        dark: NSColor(srgbRed: 0.68, green: 0.69, blue: 0.73, alpha: 1)
    )

    private static func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
        let adaptiveColor: NSColor = NSColor(name: nil) { appearance in
            let match: NSAppearance.Name? = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? dark : light
        }
        return Color(nsColor: adaptiveColor)
    }
}

struct ArcaneCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ArcaneTokens.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: ArcaneTokens.cardRadius)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            }
    }
}

struct ArcaneSectionHeader: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ArcaneStatusBadge: View {
    enum Tone {
        case positive
        case warning
        case information

        var color: Color {
            switch self {
            case .positive: ArcaneTokens.positive
            case .warning: ArcaneTokens.warning
            case .information: ArcaneTokens.information
            }
        }

        var symbolName: String {
            switch self {
            case .positive: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .information: "info.circle.fill"
            }
        }
    }

    let text: String
    let tone: Tone

    var body: some View {
        Label(text, systemImage: tone.symbolName)
            .font(.caption.weight(.medium))
            .foregroundStyle(tone.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tone.color.opacity(0.12), in: Capsule())
            .overlay {
                Capsule().strokeBorder(tone.color.opacity(0.25), lineWidth: 1)
            }
    }
}

struct ArcanePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(
                isEnabled
                    ? ArcaneTokens.primaryButtonForeground
                    : ArcaneTokens.disabledControlForeground
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                backgroundColor(isPressed: configuration.isPressed),
                in: RoundedRectangle(cornerRadius: ArcaneTokens.controlRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: ArcaneTokens.controlRadius)
                    .strokeBorder(Color.primary.opacity(isEnabled ? 0.06 : 0.12), lineWidth: 1)
            }
            .saturation(isEnabled ? 1 : 0.15)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        guard isEnabled else { return ArcaneTokens.disabledControlFill }
        return ArcaneTokens.accent.opacity(isPressed ? 0.80 : 1)
    }
}

extension View {
    func arcaneSettingsPage() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(ArcaneTokens.pagePadding)
    }
}
