import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// "Pocket Workshop" palette (docs/design.md). The icon's teal→blue stays the only saturated colour.
enum Workshop {
    static let bench = Color(hex: 0xE3D8C6)
    static let benchDark = Color(hex: 0xD3C5AE)
    static let ink = Color(hex: 0x2A251E)
    static let ink2 = Color(hex: 0x6E6355)
    static let ink3 = Color(hex: 0x9B8F7D)
    static let plastic = Color(hex: 0xF8F4EB)
    static let plasticDark = Color(hex: 0xE9E1D2)
    static let paper = Color(hex: 0xFFFEFA)
    static let amber = Color(hex: 0xF0A53A)
    static let amberDark = Color(hex: 0xB9721A)
    static let heart = Color(hex: 0xEC4468)
    static let tealDark = Color(hex: 0x0E8F82)
    static let blueDark = Color(hex: 0x2563C9)
    static let lamp = Color(hex: 0xEAF7F5)
    static let bezel = Color(hex: 0x3A342B)
    static let shadow = Color(red: 0.35, green: 0.24, blue: 0.08)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: Calm mode & motion

extension EnvironmentValues {
    /// True when Calm mode or the system's Reduce Motion is on: no animation, sound or haptics.
    @Entry var calm = false
}

/// Applies an animation only when motion is allowed.
private struct Settle<V: Equatable>: ViewModifier {
    @Environment(\.calm) private var calm
    let animation: Animation
    let value: V
    func body(content: Content) -> some View {
        content.animation(calm ? nil : animation, value: value)
    }
}

extension View {
    func settle<V: Equatable>(_ animation: Animation = .snappy(duration: 0.18), value: V) -> some View {
        modifier(Settle(animation: animation, value: value))
    }
}

enum Feedback {
    /// One light tick; never in Calm mode.
    @MainActor static func tick(calm: Bool) {
        #if os(iOS)
        guard !calm else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}

// MARK: Surfaces

/// The workbench: warm board with a faint grain.
struct BenchBackground: View {
    var body: some View {
        ZStack {
            Workshop.bench
            RadialGradient(colors: [Color.white.opacity(0.45), .clear], center: .topLeading, startRadius: 0, endRadius: 700)
            Canvas { ctx, size in
                var seed: UInt64 = 0x9E37_79B9
                for _ in 0..<Int(size.width * size.height / 700) {
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    let x = Double(seed >> 33 & 0xFFFF) / 65_535 * size.width
                    let y = Double(seed >> 17 & 0xFFFF) / 65_535 * size.height
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.4, height: 1.4)),
                             with: .color(Workshop.shadow.opacity(0.07)))
                }
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

struct ModuleSurface: ViewModifier {
    var radius: CGFloat = 24
    var screws = true
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0xFBF8F1), Workshop.plasticDark], startPoint: .top, endPoint: .bottom))
                    .shadow(color: Workshop.shadow.opacity(0.28), radius: 14, y: 10)
                    .shadow(color: Workshop.shadow.opacity(0.12), radius: 2, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white, Workshop.shadow.opacity(0.12)], startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
            )
            .overlay(alignment: .top) {
                if screws {
                    HStack { Screw(); Spacer(); Screw() }.padding(.horizontal, 12).padding(.top, 10)
                }
            }
    }
}

private struct Screw: View {
    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [.white, Color(hex: 0xC9BDA8)], center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: 6))
            .frame(width: 8, height: 8)
            .shadow(color: Workshop.shadow.opacity(0.35), radius: 0.5, y: 1)
            .accessibilityHidden(true)
    }
}

extension View {
    func workshopModule(radius: CGFloat = 24, screws: Bool = true) -> some View {
        modifier(ModuleSurface(radius: radius, screws: screws))
    }
}

/// Small monospaced uppercase label, like silk-screen on hardware.
struct Silk: View {
    let text: String
    var color = Workshop.ink2
    init(_ text: String, color: Color = Workshop.ink2) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .tracking(1.4)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Buttons

/// Chunky hardware button: gradient with a darker lip underneath that squashes when pressed.
struct ChunkyButtonStyle: ButtonStyle {
    enum Kind { case primary, plain, warning }
    var kind: Kind = .primary
    @Environment(\.isEnabled) private var enabled
    @Environment(\.calm) private var calm

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let lip: CGFloat = pressed ? 1 : 4
        configuration.label
            .font(.system(.headline, design: .rounded, weight: .semibold))
            .foregroundStyle(kind == .plain ? Workshop.ink : .white)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fill)
                    .shadow(color: lipColor, radius: 0, y: lip)
                    .shadow(color: Workshop.shadow.opacity(0.18), radius: 8, y: 6 - lip)
            )
            .offset(y: pressed ? 3 : 0)
            .opacity(enabled ? 1 : 0.4)
            .animation(calm ? nil : .snappy(duration: 0.12), value: pressed)
            .padding(.bottom, 4)
    }

    private var fill: AnyShapeStyle {
        switch kind {
        case .primary: AnyShapeStyle(LinearGradient(colors: [Brand.teal, Brand.blue], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .plain: AnyShapeStyle(LinearGradient(colors: [.white, Workshop.plastic], startPoint: .top, endPoint: .bottom))
        case .warning: AnyShapeStyle(Workshop.amber)
        }
    }
    private var lipColor: Color {
        switch kind {
        case .primary: Workshop.blueDark
        case .plain: Color(hex: 0xCDBFA5)
        case .warning: Workshop.amberDark
        }
    }
}

extension ButtonStyle where Self == ChunkyButtonStyle {
    static var chunky: ChunkyButtonStyle { ChunkyButtonStyle() }
    static var chunkyPlain: ChunkyButtonStyle { ChunkyButtonStyle(kind: .plain) }
}

// MARK: Small pieces

struct Chip: View {
    let text: String
    var color: Color = Workshop.ink2
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(0.8)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
            .overlay(Capsule().strokeBorder(color.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .foregroundStyle(color)
    }
}

struct Banner: View {
    let symbol: String
    var tint: Color = Workshop.amberDark
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).font(.body.weight(.semibold))
            Text(text).font(.callout).foregroundStyle(Workshop.ink).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.12)))
    }
}

struct EmptyShelf: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 38)).foregroundStyle(Brand.gradient)
            Text(title).font(.system(.title3, design: .rounded, weight: .bold)).foregroundStyle(Workshop.ink)
            Text(message).font(.callout).foregroundStyle(Workshop.ink2).multilineTextAlignment(.center)
        }
        .padding(32).frame(maxWidth: 420).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
