//
//  BlinkSlideshow.swift
//  Blink
//
//  Lightweight slideshow used as a feature tour and "what's in Blink"
//  surface. Hosted in a borderless floating window so it overlays
//  the rest of the desktop on demand.
//

import SwiftUI
import AppKit

struct BlinkSlide: Identifiable {
    let id = UUID()
    let title: String
    let body: String
    let symbolName: String
    let symbolHue: BlinkSlideHue
}

enum BlinkSlideHue {
    case accent
    case mono

    func color(accent: Color) -> Color {
        switch self {
        case .accent: return accent
        case .mono:   return Color.primary.opacity(0.85)
        }
    }
}

enum BlinkSlideshowDeck {
    static let slides: [BlinkSlide] = [
        BlinkSlide(
            title: "Meet Blink.",
            body: "Blink is a quiet, always-on companion living in your menu bar. It IS your cursor — a small triangle that points at what matters, listens when you ask, and stays out of the way the rest of the time.",
            symbolName: "cursorarrow.rays",
            symbolHue: .accent
        ),
        BlinkSlide(
            title: "Talk when you want help.",
            body: "Hold the push-to-talk shortcut, ask anything, let go. Blink answers in one or two sentences. It never speaks unless you ask, and it never adds suggestions you didn't request.",
            symbolName: "mic.fill",
            symbolHue: .accent
        ),
        BlinkSlide(
            title: "Blink can see your screen.",
            body: "When you ask 'what is this' or 'where do I click', Blink points at the actual element — flies the cursor to it, holds for a beat, then returns to where you were.",
            symbolName: "eye.fill",
            symbolHue: .accent
        ),
        BlinkSlide(
            title: "Knows your design tools.",
            body: "Blink ships with built-in knowledge for Onshape, Blender, Photoshop, Illustrator, and Figma. Ask 'how do I extrude this' in Onshape and Blink answers from its app-aware knowledge base, not just generic web facts.",
            symbolName: "cube.transparent",
            symbolHue: .accent
        ),
        BlinkSlide(
            title: "Spawn background agents.",
            body: "Send Blink longer jobs — research, refactors, file work, settings tweaks — and it runs them in the background without touching your screen. The agent dock keeps a calm two-color card per task so you always know what's in flight.",
            symbolName: "rectangle.stack.fill",
            symbolHue: .accent
        ),
        BlinkSlide(
            title: "Liquid glass everywhere.",
            body: "Every panel, overlay, and card uses Apple Liquid Glass materials. No dark gradients, no heavy chrome — just a translucent surface that picks up the wallpaper underneath.",
            symbolName: "sparkles",
            symbolHue: .accent
        ),
        BlinkSlide(
            title: "Your keys stay local.",
            body: "Blink talks directly to the APIs you choose — Anthropic, OpenAI, ElevenLabs, AssemblyAI. Keys live in your keychain and on disk only. No proxy, no relay, no hosted account.",
            symbolName: "lock.shield.fill",
            symbolHue: .mono
        ),
    ]
}

struct BlinkSlideshowView: View {
    let slides: [BlinkSlide]
    let accent: Color
    let onClose: () -> Void

    @State private var index: Int = 0
    @FocusState private var focused: Bool

    init(
        slides: [BlinkSlide] = BlinkSlideshowDeck.slides,
        accent: Color = Color(hex: "#7AF7B7"),
        onClose: @escaping () -> Void
    ) {
        self.slides = slides
        self.accent = accent
        self.onClose = onClose
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            background
            content
            closeButton
        }
        .frame(width: 720, height: 460)
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow)  { goPrev(); return .handled }
        .onKeyPress(.rightArrow) { goNext(); return .handled }
        .onKeyPress(.space)      { goNext(); return .handled }
        .onKeyPress(.escape)     { onClose(); return .handled }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(.thickMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.6)
            )
            .shadow(color: Color.black.opacity(0.22), radius: 24, x: 0, y: 12)
    }

    @ViewBuilder
    private var content: some View {
        let slide = currentSlide
        VStack(spacing: 24) {
            Spacer().frame(height: 14)
            Image(systemName: slide.symbolName)
                .font(.system(size: 56, weight: .regular))
                .foregroundColor(slide.symbolHue.color(accent: accent))
                .frame(width: 96, height: 96)
                .background(
                    Circle().fill(slide.symbolHue.color(accent: accent).opacity(0.12))
                )

            VStack(spacing: 14) {
                Text(slide.title)
                    .font(.system(size: 26, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundColor(Color.primary)

                Text(slide.body)
                    .font(.system(size: 14, weight: .regular))
                    .multilineTextAlignment(.center)
                    .foregroundColor(Color.primary.opacity(0.78))
                    .lineSpacing(4)
                    .frame(maxWidth: 520)
            }

            Spacer()

            controls
                .padding(.bottom, 22)
        }
        .padding(.horizontal, 36)
        .padding(.top, 22)
    }

    private var controls: some View {
        HStack(spacing: 18) {
            navButton(symbol: "chevron.left", disabled: index == 0, action: goPrev)
            dots
            navButton(symbol: "chevron.right", disabled: index == slides.count - 1, action: goNext)
        }
    }

    private func navButton(symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(disabled ? Color.primary.opacity(0.35) : Color.primary.opacity(0.85))
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(Color.white.opacity(disabled ? 0.06 : 0.12))
                )
                .overlay(
                    Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.6)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(0..<slides.count, id: \.self) { i in
                Capsule()
                    .fill(i == index ? accent : Color.primary.opacity(0.22))
                    .frame(width: i == index ? 22 : 8, height: 8)
                    .animation(.easeOut(duration: 0.22), value: index)
                    .onTapGesture { index = i }
            }
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color.primary.opacity(0.85))
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(Color.white.opacity(0.12))
                )
                .overlay(
                    Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.6)
                )
        }
        .buttonStyle(.plain)
        .padding(14)
    }

    private var currentSlide: BlinkSlide {
        slides[max(0, min(index, slides.count - 1))]
    }

    private func goNext() {
        guard index < slides.count - 1 else { return }
        index += 1
    }

    private func goPrev() {
        guard index > 0 else { return }
        index -= 1
    }
}

// MARK: - Window manager

@MainActor
final class BlinkSlideshowWindowManager {
    private var window: NSWindow?

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(
            rootView: BlinkSlideshowView(onClose: { [weak self] in
                self?.close()
            })
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.contentViewController = hosting
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = panel
    }

    func close() {
        window?.close()
        window = nil
    }
}
