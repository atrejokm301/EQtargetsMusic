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
import UIKit

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

    /// Warm glass stroke (mini player / cards) — not pure cool white.
    var glassStrokeTop: Color {
        isDark
            ? Color(red: 0.98, green: 0.94, blue: 0.88).opacity(0.12)
            : Color(red: 1.0, green: 0.99, blue: 0.96).opacity(0.55)
    }

    var glassStrokeBottom: Color {
        isDark
            ? Color(red: 0.98, green: 0.94, blue: 0.88).opacity(0.03)
            : Color(red: 0.90, green: 0.84, blue: 0.72).opacity(0.25)
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

// MARK: - Grok menu + scroll chrome environment

private struct GrokOpenMenuKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

/// Scroll offset reporter injected by `grokStyleNavigationChrome`; consumed by `grokScrollEdgeBlur`.
private struct GrokScrollOffsetHandlerKey: EnvironmentKey {
    static let defaultValue: ((CGFloat) -> Void)? = nil
}

extension EnvironmentValues {
    /// Opens the root hamburger / settings sheet. Set once on the TabView stacks.
    var grokOpenMenu: (() -> Void)? {
        get { self[GrokOpenMenuKey.self] }
        set { self[GrokOpenMenuKey.self] = newValue }
    }

    /// Called by lists/scroll views with the current vertical scroll offset (points past top).
    fileprivate var grokScrollOffsetHandler: ((CGFloat) -> Void)? {
        get { self[GrokScrollOffsetHandlerKey.self] }
        set { self[GrokScrollOffsetHandlerKey.self] = newValue }
    }
}

extension View {
    func glassCard(corner: CGFloat = 20) -> some View {
        modifier(GlassCard(corner: corner))
    }

    /// Wide iOS 26/27 chrome used on every `NavigationStack` screen:
    /// - Short progressive blur under the status/title band (~140–170pt, not half-screen)
    /// - Title (“Music”, etc.) hides when scrolling down, returns when scrolling back up
    /// - Menu / trailing actions stay visible; no solid toolbar hairline
    func grokStyleNavigationChrome<Trailing: View>(
        title: String,
        showsBack: Bool = false,
        showsMenu: Bool = true,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) -> some View {
        modifier(
            GrokNavChromeModifier(
                title: title,
                showsBack: showsBack,
                showsMenu: showsMenu,
                trailing: trailing
            )
        )
    }

    func grokStyleNavigationChrome(
        title: String,
        showsBack: Bool = false,
        showsMenu: Bool = true
    ) -> some View {
        grokStyleNavigationChrome(title: title, showsBack: showsBack, showsMenu: showsMenu) {
            EmptyView()
        }
    }

    /// Apply on every `List` / `ScrollView` under `grokStyleNavigationChrome`.
    /// Soft native edge + reports scroll so the title can collapse app-wide.
    func grokScrollEdgeBlur() -> some View {
        modifier(GrokScrollEdgeBlurModifier())
    }

    func messagesStyleNavigationBar() -> some View {
        grokStyleNavigationChrome(title: "")
    }
}

// MARK: - Wide nav chrome (half-window blur + collapsing title)

private struct GrokNavChromeModifier<Trailing: View>: ViewModifier {
    let title: String
    var showsBack: Bool
    var showsMenu: Bool
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.grokTheme) private var theme
    @Environment(\.grokOpenMenu) private var openMenu
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    /// Title visible near top; false after user scrolls content up.
    @State private var titleVisible = true

    /// Hysteresis avoids flicker at the threshold.
    private let hideTitleAfter: CGFloat = 28
    private let showTitleBelow: CGFloat = 10

    func body(content: Content) -> some View {
        content
            // Empty system title — principal title can fade on scroll.
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            // Let iOS 26 draw **system Liquid Glass** on the bar (Grok / Messages style).
            // Hiding the bar or forcing a clear UIKit appearance kills real frosted glass.
            // Visible so system Liquid Glass can render (hidden = no frosted bar).
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            // Progressive frosted edge where content scrolls under chrome (Liquid Glass).
            .scrollEdgeEffectStyle(.soft, for: .top)
            .environment(\.grokScrollOffsetHandler, handleScrollOffset)
            .toolbar {
                if showsMenu, let openMenu {
                    ToolbarItem(placement: .topBarLeading) {
                        // Plain style — iOS 26 already puts toolbar items in a Liquid Glass
                        // group. `.buttonStyle(.glass)` stacks a second capsule (bubble-in-bubble).
                        Button(action: openMenu) {
                            Image(systemName: "line.3.horizontal")
                                .font(.app(size: 17, weight: .semibold))
                                .foregroundStyle(theme.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Menu")
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.app(size: 17, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .opacity(titleVisible ? 1 : 0)
                        .offset(y: titleVisible ? 0 : -8)
                        .accessibilityHidden(!titleVisible)
                        .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Glass capsule for trailing controls (matches system Liquid Glass chrome).
                    trailing()
                        .tint(theme.accent)
                }
            }
            .navigationBarBackButtonHidden(false)
            // Soft frosted veil under the system glass bar (short — not half-screen).
            // Complements scroll-edge glass; mask dissolves so there’s no hard line.
            .overlay(alignment: .top) {
                GeometryReader { geo in
                    let status = max(geo.safeAreaInsets.top, 47)
                    let fadeHeight = status + 44 + 72
                    GrokLiquidGlassHeaderVeil(height: fadeHeight)
                        .frame(width: geo.size.width, height: fadeHeight, alignment: .top)
                        .allowsHitTesting(false)
                }
                .frame(height: 190, alignment: .top)
                .allowsHitTesting(false)
                .ignoresSafeArea(edges: .top)
            }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.22),
                value: titleVisible
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
    }

    private func handleScrollOffset(_ y: CGFloat) {
        if titleVisible, y > hideTitleAfter {
            titleVisible = false
        } else if !titleVisible, y < showTitleBelow {
            titleVisible = true
        }
    }
}

// MARK: - Scroll tracking (every List / ScrollView)

private struct GrokScrollEdgeBlurModifier: ViewModifier {
    @Environment(\.grokScrollOffsetHandler) private var reportOffset

    func body(content: Content) -> some View {
        content
            // Soft Liquid Glass scroll-edge (the frosted progressive blur under bars).
            .scrollEdgeEffectStyle(.soft, for: .top)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, newOffset in
                reportOffset?(newOffset)
            }
    }
}

// MARK: - Liquid Glass header veil (frosted + blurry, short band)

/// Frosted Liquid Glass under the nav — **full frost at the very top** (status bar),
/// then soft dissolve below the title. ~3% more transparent than the first glass pass.
struct GrokLiquidGlassHeaderVeil: View {
    @Environment(\.grokTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var height: CGFloat

    /// Lower = more transparent. 0.60 ≈ 40% more open than full cover.
    private let clarity: Double = 0.60

    private var glass: Glass {
        // Liquid Glass tint: cool white sheen (light) / faint white on black (dark).
        let tint = scheme == .dark
            ? Color.white.opacity(0.04 * clarity)
            : Color.white.opacity(0.42 * clarity)
        return .regular.tint(tint).interactive(false)
    }

    var body: some View {
        ZStack(alignment: .top) {
            if reduceTransparency {
                LinearGradient(
                    stops: [
                        .init(color: theme.background.opacity(0.94 * clarity), location: 0),
                        .init(color: theme.background.opacity(0.68 * clarity), location: 0.40),
                        .init(color: theme.background.opacity(0), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                // 1) Full-height Liquid Glass — NO mask at top so status bar is real frost, not a fade.
                GlassEffectContainer {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .glassEffect(glass, in: Rectangle())
                }
                // Only dissolve the *bottom* of the glass; top ~40% stays fully frosted.
                .mask(bottomOnlyDissolveMask)

                // 2) Extra frost locked to the very top (status + title) — kills “plain fade” look.
                Rectangle()
                    .fill(.ultraThickMaterial)
                    .opacity((scheme == .dark ? 0.62 : 0.48) * clarity)
                    .mask(statusBarFrostMask)

                Rectangle()
                    .fill(.bar)
                    .opacity((scheme == .dark ? 0.72 : 0.58) * clarity)
                    .mask(statusBarFrostMask)

                Rectangle()
                    .fill(.regularMaterial)
                    .opacity((scheme == .dark ? 0.38 : 0.32) * clarity)
                    .mask(statusBarFrostMask)

                // 3) Soft frost continues under the title, then clears (not at the extreme top).
                Rectangle()
                    .fill(.thinMaterial)
                    .opacity((scheme == .dark ? 0.40 : 0.30) * clarity)
                    .mask(underTitleFrostMask)

                // 4) Subtle glass sheen — keep weak so top still reads as blur/frost, not white wash.
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity((scheme == .dark ? 0.06 : 0.18) * clarity), location: 0),
                        .init(color: Color.white.opacity((scheme == .dark ? 0.02 : 0.06) * clarity), location: 0.35),
                        .init(color: theme.background.opacity((scheme == .dark ? 0.22 : 0.08) * clarity), location: 0.62),
                        .init(color: theme.background.opacity(0), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .top)
        .accessibilityHidden(true)
    }

    /// Glass stays solid through status/title; only the lower tail dissolves.
    private var bottomOnlyDissolveMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0.00),
                .init(color: .black, location: 0.42), // full frost through status + title
                .init(color: .black.opacity(0.75), location: 0.58),
                .init(color: .black.opacity(0.32), location: 0.76),
                .init(color: .black.opacity(0.08), location: 0.90),
                .init(color: .clear, location: 1.00)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Peak frost only on the extreme top (status bar / Dynamic Island band).
    private var statusBarFrostMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0.00),
                .init(color: .black, location: 0.22),
                .init(color: .black.opacity(0.70), location: 0.38),
                .init(color: .black.opacity(0.20), location: 0.52),
                .init(color: .clear, location: 0.68)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var underTitleFrostMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.55), location: 0.18),
                .init(color: .black.opacity(0.75), location: 0.40),
                .init(color: .black.opacity(0.25), location: 0.62),
                .init(color: .clear, location: 0.82)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Navigation appearance (allow system Liquid Glass)

enum AppChrome {
    /// iOS 26/27: do **not** force a clear nav bar — that disables system Liquid Glass.
    /// Only set fonts + kill the old 1pt hairline shadow.
    static func configureNavigationBar() {
        let titleFont = AppTypography.uiFont(size: 17, weight: .semibold)
        let largeFont = AppTypography.uiFont(size: 34, weight: .bold)

        // Default (glass-capable) background — system owns the frosted material.
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.shadowColor = .clear
        appearance.shadowImage = UIImage()
        appearance.titleTextAttributes = [
            .font: titleFont,
            .foregroundColor: UIColor.label
        ]
        appearance.largeTitleTextAttributes = [
            .font: largeFont,
            .foregroundColor: UIColor.label
        ]

        let nav = UINavigationBar.appearance()
        nav.standardAppearance = appearance
        nav.scrollEdgeAppearance = appearance
        nav.compactAppearance = appearance
        nav.compactScrollEdgeAppearance = appearance
        nav.isTranslucent = true
        nav.prefersLargeTitles = false
    }
}
