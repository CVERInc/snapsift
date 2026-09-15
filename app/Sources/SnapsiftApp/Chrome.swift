import SwiftUI
import Signet
#if os(macOS)
import AppKit

/// Whole-window frosted glass (NSVisualEffectView, behind-window blending) —
/// the CVER "liquid glass" backdrop. The reef tint layer in `ReefBackdrop`
/// sits above it so the brand teal survives while desktop light bleeds
/// through the chrome.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}
#endif

/// Springy press + hover lift for card-sized buttons (the cubeconjure
/// GlassButton recipe): scale down on press, gentle lift + deeper shadow on
/// hover. Chrome-only feedback — nothing tints the content.
struct PressableCard: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }
    private struct StyledLabel: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.96 : (hovering ? 1.02 : 1))
                .shadow(color: .black.opacity(hovering ? 0.3 : 0.15),
                        radius: hovering ? 10 : 6, y: hovering ? 6 : 3)
                .animation(.spring(response: 0.25, dampingFraction: 0.7),
                           value: configuration.isPressed)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// Exposes hover state to stateless row/card builder functions.
struct Hovering<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content
    @State private var hovering = false
    var body: some View {
        content(hovering)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Hover feedback for photo cards: a faint mint hairline + a hair of lift.
/// The pixels stay untouched (no tint, no opacity) — color truth is sacred
/// on the review grid; feedback lives on the chrome only.
struct CardHover: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: CVERRadius.control, style: .continuous)
                    .strokeBorder(Color.reefMint.opacity(hovering ? 0.35 : 0), lineWidth: 1)
            )
            .scaleEffect(hovering ? 1.012 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func cardHover() -> some View { modifier(CardHover()) }
}

/// The window backdrop: frosted glass under a strong reef tint. Chrome only —
/// surfaces that must read color-true (the photo grid, the loupe) keep their
/// opaque `reefGround`/`reefDeep` fills per the Signet rule: glass is for
/// chrome, never for a canvas where color accuracy matters.
struct ReefBackdrop: View {
    var body: some View {
        #if os(macOS)
        ZStack {
            VisualEffectBackground().ignoresSafeArea()
            Color.reefGround.opacity(0.85).ignoresSafeArea()
        }
        #else
        Color.reefGround.ignoresSafeArea()
        #endif
    }
}
