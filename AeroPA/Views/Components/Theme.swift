import SwiftUI
import AeroPACore

/// Design tokens. Graphite surfaces, white type, one restrained blue accent.
enum Theme {
    static let background = Color(red: 0.035, green: 0.039, blue: 0.047)
    static let surface = Color(red: 0.085, green: 0.093, blue: 0.108)
    static let surfaceRaised = Color(red: 0.12, green: 0.13, blue: 0.15)
    static let hairline = Color.white.opacity(0.07)
    static let accent = Color(red: 0.36, green: 0.58, blue: 1.0)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.58)
    static let textTertiary = Color.white.opacity(0.36)
    static let positive = Color(red: 0.36, green: 0.84, blue: 0.56)
    static let caution = Color(red: 1.0, green: 0.75, blue: 0.3)
    static let negative = Color(red: 1.0, green: 0.42, blue: 0.4)

    static let corner: CGFloat = 20
    static let spacing: CGFloat = 16

    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).strokeBorder(Theme.hairline))
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(Theme.textTertiary)
    }
}

struct StatusDot: View {
    let color: Color
    var pulsing = false
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(color.opacity(0.5), lineWidth: 6).scaleEffect(animate ? 1.8 : 1).opacity(animate ? 0 : 0.6))
            .onAppear {
                guard pulsing else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { animate = true }
            }
    }
}

extension ConnectionState {
    var color: Color {
        switch self {
        case .receiving: return Theme.positive
        case .listening, .stale: return Theme.caution
        case .lost, .failed: return Theme.negative
        case .disconnected: return Theme.textTertiary
        }
    }
}

extension View {
    func screenBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }

    /// Medium impact haptic on change (iOS 17 `sensoryFeedback`).
    @ViewBuilder func hapticFeedback<T: Equatable>(trigger: T) -> some View {
        #if os(iOS)
        sensoryFeedback(.impact(weight: .medium), trigger: trigger)
        #else
        self
        #endif
    }

    @ViewBuilder func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder func largeTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.large)
        #else
        self
        #endif
    }
}

extension Color {
    init?(hex: String?) {
        guard var h = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// Binding helpers so views can edit settings without holding business logic.
extension CompanionCoordinator {
    func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: keyPath] },
                set: { newValue in self.updateSettings { $0[keyPath: keyPath] = newValue } })
    }

    func volumeBinding(_ ch: AudioChannel) -> Binding<Double> {
        Binding(get: { Double(self.settings.volume(ch)) },
                set: { v in self.updateSettings { $0.setVolume(Float(v), ch) } })
    }
}

enum Format {
    static func feet(_ v: Double?) -> String {
        guard let v else { return "—" }
        return Int(v.rounded()).formatted()
    }
    static func knots(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))" } ?? "—" }
    static func fpm(_ v: Double?) -> String {
        guard let v else { return "—" }
        let r = Int((v / 10).rounded()) * 10
        return (r > 0 ? "+" : "") + r.formatted()
    }
    static func heading(_ v: Double?) -> String {
        guard let v else { return "—" }
        let h = Int(v.rounded()) % 360
        return String(format: "%03d°", h == 0 ? 360 : h)
    }
}
