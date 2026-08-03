//
//  GrokTheme.swift
//  EQtargetsMusic
//
//  Liquid-glass theme aligned with Grok Dev ui-ux-meticulous guidelines:
//  - 4/8pt spacing
//  - True black dark mode (NOT navy)
//  - Creamy light mode
//  - Clear hierarchy, AA contrast
//

import SwiftUI

enum AppAccentTheme: String, CaseIterable, Identifiable, Codable {
    case blue
    case green
    case crimson
    case orange
    case yellow
    case purple
    case cyan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blue: return "Blue"
        case .green: return "Green"
        case .crimson: return "Crimson"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .purple: return "Purple"
        case .cyan: return "Cyan"
        }
    }

    func color(for isDark: Bool) -> Color {
        accentColor(isDark: isDark)
    }

    func accentColor(isDark: Bool) -> Color {
        switch self {
        case .blue:
            return isDark ? Color(red: 0.35, green: 0.70, blue: 1.00) : Color(red: 0.00, green: 0.45, blue: 0.85)
        case .green:
            return isDark ? Color(red: 0.35, green: 0.88, blue: 0.55) : Color(red: 0.08, green: 0.62, blue: 0.32)
        case .crimson:
            return isDark ? Color(red: 1.00, green: 0.30, blue: 0.40) : Color(red: 0.75, green: 0.05, blue: 0.20)
        case .orange:
            return isDark ? Color(red: 1.00, green: 0.62, blue: 0.25) : Color(red: 0.90, green: 0.42, blue: 0.05)
        case .yellow:
            return isDark ? Color(red: 1.00, green: 0.85, blue: 0.20) : Color(red: 0.78, green: 0.55, blue: 0.00)
        case .purple:
            return isDark ? Color(red: 0.75, green: 0.50, blue: 1.00) : Color(red: 0.45, green: 0.15, blue: 0.75)
        case .cyan:
            return isDark ? Color(red: 0.25, green: 0.88, blue: 0.95) : Color(red: 0.00, green: 0.58, blue: 0.68)
        }
    }

    func accentSecondaryColor(isDark: Bool) -> Color {
        switch self {
        case .blue:
            return isDark ? Color(red: 0.55, green: 0.85, blue: 1.00) : Color(red: 0.20, green: 0.60, blue: 0.95)
        case .green:
            return isDark ? Color(red: 0.60, green: 0.95, blue: 0.75) : Color(red: 0.25, green: 0.75, blue: 0.45)
        case .crimson:
            return isDark ? Color(red: 1.00, green: 0.50, blue: 0.60) : Color(red: 0.88, green: 0.20, blue: 0.35)
        case .orange:
            return isDark ? Color(red: 1.00, green: 0.80, blue: 0.45) : Color(red: 0.98, green: 0.58, blue: 0.20)
        case .yellow:
            return isDark ? Color(red: 1.00, green: 0.92, blue: 0.45) : Color(red: 0.88, green: 0.68, blue: 0.10)
        case .purple:
            return isDark ? Color(red: 0.85, green: 0.70, blue: 1.00) : Color(red: 0.58, green: 0.30, blue: 0.85)
        case .cyan:
            return isDark ? Color(red: 0.55, green: 0.95, blue: 1.00) : Color(red: 0.15, green: 0.70, blue: 0.80)
        }
    }
}

struct GrokTheme {
    let isDark: Bool
    var accentTheme: AppAccentTheme = .blue

    /// True black / deep charcoal — never navy
    var background: Color {
        isDark ? Color(red: 0.0, green: 0.0, blue: 0.0) : Color(red: 0.97, green: 0.95, blue: 0.92)
    }

    var elevated: Color {
        // Near-clear in dark so true black bleeds through (avoid grey slabs).
        isDark ? Color.white.opacity(0.04) : Color.white.opacity(0.72)
    }

    var cardFill: Color {
        // Very light veil only — black background should remain the dominant surface.
        isDark ? Color.white.opacity(0.028) : Color.white.opacity(0.55)
    }

    var accent: Color {
        accentTheme.accentColor(isDark: isDark)
    }

    var accentSecondary: Color {
        accentTheme.accentSecondaryColor(isDark: isDark)
    }

    var primaryText: Color {
        isDark ? Color.white.opacity(0.95) : Color(red: 0.10, green: 0.09, blue: 0.08)
    }

    var secondaryText: Color {
        isDark ? Color.white.opacity(0.58) : Color(red: 0.38, green: 0.35, blue: 0.32)
    }

    var tertiaryText: Color {
        isDark ? Color.white.opacity(0.38) : Color(red: 0.55, green: 0.50, blue: 0.46)
    }

    var targetTint: Color {
        isDark ? Color(red: 0.40, green: 0.75, blue: 1.0) : Color(red: 0.15, green: 0.45, blue: 0.78)
    }

    var fineTint: Color {
        isDark ? Color(red: 1.0, green: 0.70, blue: 0.35) : Color(red: 0.88, green: 0.45, blue: 0.12)
    }

    var danger: Color {
        isDark ? Color(red: 1.0, green: 0.40, blue: 0.42) : Color(red: 0.85, green: 0.22, blue: 0.25)
    }

    var separator: Color {
        isDark ? Color.white.opacity(0.03) : Color.black.opacity(0.03)
    }

    var positive: Color {
        isDark ? Color(red: 0.40, green: 0.90, blue: 0.60) : Color(red: 0.12, green: 0.55, blue: 0.35)
    }
}

private struct GrokThemeKey: EnvironmentKey {
    static let defaultValue = GrokTheme(isDark: true)
}

extension EnvironmentValues {
    var grokTheme: GrokTheme {
        get { self[GrokThemeKey.self] }
        set { self[GrokThemeKey.self] = newValue }
    }
}

// MARK: - Glass

struct LiquidGlassBackground: View {
    @Environment(\.grokTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            Circle()
                .fill(theme.accent.opacity(theme.isDark ? 0.08 : 0.08))
                .frame(width: 320, height: 320)
                .blur(radius: 90)
                .offset(x: -120, y: -200)

            Circle()
                .fill(theme.accentSecondary.opacity(theme.isDark ? 0.05 : 0.06))
                .frame(width: 280, height: 280)
                .blur(radius: 80)
                .offset(x: 140, y: 120)

            if theme.isDark {
                // Barely-there top sheen — keep pure black dominant
                LinearGradient(
                    colors: [Color.white.opacity(0.012), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
                .ignoresSafeArea()
            }
        }
    }
}

struct GlassCard: ViewModifier {
    var corner: CGFloat = 20
    @Environment(\.grokTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    if theme.isDark {
                        // No frosted material in dark — it greys out true black.
                        // Bare white veil so the pure black background bleeds through.
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .fill(Color.white.opacity(0.035))
                    } else {
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .fill(theme.cardFill)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(scheme == .dark ? 0.10 : 0.40),
                                    Color.white.opacity(scheme == .dark ? 0.02 : 0.10)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: scheme == .dark ? 0.5 : 0.6
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            // Soft shadow — avoid extra grey haze in dark mode
            .shadow(
                color: .black.opacity(scheme == .dark ? 0.18 : 0.05),
                radius: scheme == .dark ? 10 : 16,
                y: scheme == .dark ? 4 : 8
            )
    }
}

extension View {
    func glassCard(corner: CGFloat = 20) -> some View {
        modifier(GlassCard(corner: corner))
    }
}
