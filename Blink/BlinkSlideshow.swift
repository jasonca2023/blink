//
//  BlinkSlideshow.swift
//  Blink
//
//  Lightweight slideshow used as a feature tour and "what's in Blink"
//  surface. Hosted in a borderless floating window so it overlays
//  the rest of the desktop on demand.
//
//  Hallmark · component: tour-card · genre: atmospheric · theme: custom (Blink Dusk)
//  accent: DS.Colors.accent (blue 600 default, user-configurable) · paper: DS.Colors.background
//  icon: ring motif (1.5 pt stroke, 7 % fill) — matches BlinkListeningIndicator ring language
//  blooms: two fixed (top-centre primary + bottom-trailing dim) · reduced-motion: opacity-only
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
            title: "Knows your creative tools.",
            body: "When you're in Onshape, Blender, Photoshop, Illustrator, or Figma, Blink answers how-to questions from a built-in, app-aware knowledge base. Ask 'how do I extrude this' and it draws on real app knowledge — not just generic web facts — recognizing the focused app even in a browser tab.",
            symbolName: "pencil.and.ruler.fill",
            symbolHue: .accent
        ),
        BlinkSlide(
            title: "Speaks back to you.",
            body: "Blink reads its replies aloud using your choice of voice service — OpenAI, ElevenLabs, Deepgram, or Cartesia. Pick a voice in settings, or turn TTS off entirely. Voice is optional and switches without a restart.",
            symbolName: "speaker.wave.3.fill",
            symbolHue: .accent
        ),
        BlinkSlide(
            title: "Spawn background agents.",
            body: "Send Blink longer jobs — research, refactors, file work, settings tweaks — and it runs them in the background without touching your screen. The agent dock keeps a calm two-color card per task so you always know what's in flight.",
            symbolName: "rectangle.stack.fill",
            symbolHue: .accent
        ),
        BlinkSlide(
            title: "Answers close to you.",
            body: "Blink drops its reply as a compact card beside your cursor — no app-switching, no modal dialogs, no dock bounce. Read it, dismiss it, or let it fade. Your focus stays on what you were doing.",
            symbolName: "bubble.left.fill",
            symbolHue: .accent
        ),
        BlinkSlide(
            title: "Your keys stay local.",
            body: "Blink talks directly to the APIs you configure — Anthropic, OpenAI, ElevenLabs, Deepgram, or AssemblyAI. Keys live in your keychain and on disk only. No proxy, no relay, no hosted account required.",
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
        accent: Color = DS.Colors.accent,
        onClose: @escaping () -> Void
    ) {
        self.slides = slides
        self.accent = accent
        self.onClose = onClose
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            background
            contentStack
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

    // MARK: - Background

    private var background: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(DS.Colors.background)

            // Primary bloom — top-centre, shifts hue with the slide (atmospheric rule: bloom 1)
            RadialGradient(
                gradient: Gradient(colors: [
                    currentSlide.symbolHue.color(accent: accent).opacity(0.11),
                    Color.clear
                ]),
                center: UnitPoint(x: 0.5, y: 0.06),
                startRadius: 0,
                endRadius: 300
            )
            .animation(DS.Animation.blinkSpringSettle, value: index)

            // Secondary dim bloom — bottom-trailing, fixed, purely for depth (bloom 2 of 2 max)
            RadialGradient(
                gradient: Gradient(colors: [
                    DS.Colors.accent.opacity(0.05),
                    Color.clear
                ]),
                center: UnitPoint(x: 0.88, y: 0.94),
                startRadius: 0,
                endRadius: 160
            )

            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.40), radius: 36, x: 0, y: 18)
    }

    // MARK: - Content

    private var contentStack: some View {
        VStack(spacing: 0) {
            slideArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 48)
                .padding(.top, 36)
                .padding(.bottom, 24)

            DS.Colors.borderSubtle.frame(height: 0.6)

            controls
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
        }
    }

    private var slideArea: some View {
        let slide = currentSlide
        return VStack(spacing: 22) {
            iconView(slide: slide)
            textView(slide: slide)
        }
        .id(index)
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))
        .animation(.easeOut(duration: 0.22), value: index)
    }

    private func iconView(slide: BlinkSlide) -> some View {
        let hueColor = slide.symbolHue.color(accent: accent)
        return ZStack {
            // Outer glow bloom — atmospheric depth
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [hueColor.opacity(0.18), Color.clear]),
                        center: .center,
                        startRadius: 0,
                        endRadius: 80
                    )
                )
                .frame(width: 160, height: 160)

            // Ring motif — same visual language as BlinkListeningIndicator's drawn-on ring:
            // emphasis on the stroke (1.5 pt), minimal fill (7 %), no heavy filled circle.
            ZStack {
                Circle()
                    .fill(hueColor.opacity(0.07))
                Circle()
                    .stroke(hueColor.opacity(0.45), lineWidth: 1.5)
            }
            .frame(width: 86, height: 86)

            Image(systemName: slide.symbolName)
                .font(.system(size: 32, weight: .medium))
                .foregroundColor(hueColor)
        }
    }

    private func textView(slide: BlinkSlide) -> some View {
        VStack(spacing: 11) {
            Text(slide.title)
                .font(DS.Typography.heading(25))
                .tracking(-0.3)
                .multilineTextAlignment(.center)
                .foregroundColor(DS.Colors.textPrimary)

            Text(slide.body)
                .font(.system(size: 13.5, weight: .regular))
                .multilineTextAlignment(.center)
                .foregroundColor(DS.Colors.textSecondary)
                .lineSpacing(3.5)
                .frame(maxWidth: 500)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            navButton(symbol: "chevron.left", disabled: index == 0, action: goPrev)
            Spacer()
            dots
            Spacer()
            navButton(symbol: "chevron.right", disabled: index == slides.count - 1, action: goNext)
        }
    }

    private func navButton(symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .dsIconButtonStyle(size: 30)
        .disabled(disabled)
        .opacity(disabled ? 0.28 : 1.0)
        .animation(.easeOut(duration: DS.Animation.fast), value: disabled)
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(0..<slides.count, id: \.self) { i in
                let isActive = i == index
                ZStack {
                    if isActive {
                        Capsule()
                            .fill(accent.opacity(0.28))
                            .frame(width: 26, height: 8)
                            .blur(radius: 3)
                    }
                    Capsule()
                        .fill(isActive ? accent : DS.Colors.borderStrong)
                        .frame(width: isActive ? 22 : 7, height: 7)
                }
                .animation(DS.Animation.blinkSpring, value: index)
                .onTapGesture { navigate(to: i) }
                .pointerCursor()
            }
        }
    }

    // MARK: - Close

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
        }
        .dsIconButtonStyle(size: 26, isDestructiveOnHover: true, tooltip: "Close", tooltipAlignment: .trailing)
        .padding(12)
    }

    // MARK: - Helpers

    private var currentSlide: BlinkSlide {
        slides[max(0, min(index, slides.count - 1))]
    }

    private func goNext() {
        guard index < slides.count - 1 else { return }
        withAnimation(DS.Animation.blinkSpring) { index += 1 }
    }

    private func goPrev() {
        guard index > 0 else { return }
        withAnimation(DS.Animation.blinkSpring) { index -= 1 }
    }

    private func navigate(to i: Int) {
        withAnimation(DS.Animation.blinkSpring) { index = i }
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
