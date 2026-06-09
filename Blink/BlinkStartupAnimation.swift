//
//  BlinkStartupAnimation.swift
//  Blink
//
//  The launch experience. Blink is a menu-bar app with no main window, so this
//  is its "open": a borderless full-screen panel darkens the display, draws
//  Blink's listening indicator (the push-to-talk pupil + ring) on, breathes,
//  shows the wordmark + tagline, then hands off to an embedded feature tour
//  over the same dark backdrop. A Get Started button on the last slide ends the
//  intro and reveals the (already-running) app. It stays click-through and
//  non-focus-stealing during the intro, becomes interactive for the tour, and
//  honors Reduce Motion.
//
//  Hallmark · component: launch-experience · genre: atmospheric · accent: cursor-blue
//  motion: fade + draw-on · named ease-out / ease-in only, no spring/overshoot
//  canvas: tinted near-black (not #000) + one fixed accent bloom · reduced-motion: yes
//  pre-emit critique: P5 H4 E5 S4 R5 V4
//

import AppKit
import SwiftUI

/// A borderless panel that can still take key focus, so the embedded tour's
/// buttons and arrow-key navigation work once the intro hands off to it.
private final class SplashPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Owns the splash panel for the whole intro. It retains itself while playing
/// (so the caller can fire-and-forget) and releases once Get Started is hit.
@MainActor
final class BlinkStartupAnimationController {
    /// Set once the feature tour has been shown, so it only appears on first
    /// launch. The intro animation still plays every launch.
    private static let tourShownKey = "blink.startupTourShown"

    private var panel: SplashPanel?
    private var selfRetain: BlinkStartupAnimationController?

    /// Plays the launch experience once. Safe to call from
    /// `applicationDidFinishLaunching`; it does its own teardown.
    static func playOnLaunch() {
        let controller = BlinkStartupAnimationController()
        controller.selfRetain = controller
        // Defer to the next runloop turn so the panel is created and the
        // timeline is scheduled AFTER the rest of launch (companionManager
        // .start(), etc.) finishes and frees the main thread. Otherwise the
        // timeline's timed steps bunch up behind that blocking work and the
        // animation collapses into a single black flash on slower machines.
        DispatchQueue.main.async { controller.show() }
    }

    private func show() {
        // If the display isn't ready yet (e.g. launched at login before the
        // Spaces come up), just skip the flourish rather than risk a bad frame.
        guard let screen = NSScreen.main else {
            finish()
            return
        }

        let frame = screen.frame
        let panel = SplashPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Transparent, always-on-top. The dark canvas is drawn by the SwiftUI
        // view (so it can fade). During the intro it's click-through and never
        // takes focus; the tour hand-off flips that via `enableInteraction()`.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false

        let showsTour = !UserDefaults.standard.bool(forKey: Self.tourShownKey)
        let hosting = NSHostingView(
            rootView: BlinkStartupView(
                showsTour: showsTour,
                onTourBegan: { [weak self] in
                    UserDefaults.standard.set(true, forKey: Self.tourShownKey)
                    self?.enableInteraction()
                },
                onFinish: { [weak self] in self?.dismiss() }
            )
        )
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        panel.contentView = hosting
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Make the panel interactive for the embedded tour: accept clicks, take
    /// key focus for arrow-key nav, and bring the app forward.
    private func enableInteraction() {
        panel?.ignoresMouseEvents = false
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Fade the whole intro out, then tear down. The app underneath is already
    /// running, so this just removes the overlay.
    private func dismiss() {
        guard let panel else { finish(); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.finish()
        })
    }

    private func finish() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        selfRetain = nil
    }
}

// MARK: - Motion tokens (Hallmark)

/// Hallmark's three named easings (references/motion.md) — exponential, not the
/// system defaults. Elements entering decelerate into place (`easeOut`);
/// elements leaving accelerate away (`easeIn`). No spring, no overshoot.
private enum SplashMotion {
    static func easeOut(_ duration: Double) -> Animation { .timingCurve(0.16, 1, 0.3, 1, duration: duration) }
    static func easeIn(_ duration: Double) -> Animation { .timingCurve(0.7, 0, 0.84, 0, duration: duration) }
}

/// Tinted near-black canvas — not pure #000, which reads flat and synthetic
/// (Hallmark anti-pattern). Cooled toward the cursor-blue accent.
private let splashCanvas = Color(hex: "#05070C")

// MARK: - Root view

/// The launch experience: intro mark, then the embedded tour, over a shared
/// dark backdrop. `onTourBegan` tells the controller to make the panel
/// interactive; `onGetStarted` ends the intro.
private struct BlinkStartupView: View {
    let showsTour: Bool
    let onTourBegan: () -> Void
    let onFinish: () -> Void

    @State private var canvasOpacity: Double = 0
    @State private var drawProgress: CGFloat = 0
    @State private var isPulsing = false
    @State private var wordmarkOpacity: Double = 0
    @State private var introOpacity: Double = 1
    @State private var introRemoved = false
    @State private var showTour = false
    @State private var tourOpacity: Double = 0

    private let accent = DS.Colors.overlayCursorBlue

    var body: some View {
        ZStack {
            splashCanvas
                .ignoresSafeArea()
                .opacity(canvasOpacity)

            // Two fixed accent blooms — the atmospheric ground that keeps the
            // canvas from reading as flat black and fills the negative space
            // with depth rather than emptiness. No animation (genre rule:
            // atmospheric allows up to two fixed blooms).
            RadialGradient(
                gradient: Gradient(colors: [accent.opacity(0.13), .clear]),
                center: UnitPoint(x: 0.42, y: 0.46),
                startRadius: 0,
                endRadius: 360
            )
            .ignoresSafeArea()
            .blendMode(.plusLighter)
            .opacity(canvasOpacity)

            RadialGradient(
                gradient: Gradient(colors: [accent.opacity(0.09), .clear]),
                center: UnitPoint(x: 0.82, y: 0.2),
                startRadius: 0,
                endRadius: 420
            )
            .ignoresSafeArea()
            .blendMode(.plusLighter)
            .opacity(canvasOpacity)

            if !introRemoved {
                introMark.opacity(introOpacity)
            }

            if showTour {
                BlinkStartupTour(accent: DS.Colors.accent, onGetStarted: onFinish)
                    .opacity(tourOpacity)
            }
        }
        .onAppear(perform: runTimeline)
    }

    private var introMark: some View {
        VStack(spacing: 26) {
            // Blink's listening indicator — the ring draws itself on, then the
            // pupil inside breathes, like the cursor while you hold ctrl+option.
            BlinkListeningIndicator(drawProgress: drawProgress, isPulsing: isPulsing, color: accent)
                .frame(width: 220, height: 220)

            VStack(spacing: 12) {
                Text("Blink")
                    .font(.system(size: 56, weight: .semibold))
                    .tracking(-1.6)
                    .foregroundStyle(DS.Colors.textPrimary)

                Text("A cursor that listens")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(DS.Colors.textSecondary)
            }
            .opacity(wordmarkOpacity)
        }
    }

    private func runTimeline() {
        // Reduce Motion: spatial motion collapses to an opacity crossfade — no
        // draw-on, no breathing pulse.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            drawProgress = 1
            withAnimation(SplashMotion.easeOut(0.5)) {
                canvasOpacity = 1
                wordmarkOpacity = 1
            }
            at(2.4) { withAnimation(SplashMotion.easeIn(0.5)) { introOpacity = 0 } }
            at(3.0) { beginTour() }
            return
        }

        // Darken the screen.
        withAnimation(SplashMotion.easeOut(0.5)) { canvasOpacity = 1 }

        // The ring draws itself on — slow, deliberate, decelerating into place.
        at(0.6) { withAnimation(SplashMotion.easeOut(1.3)) { drawProgress = 1 } }

        // The wordmark + tagline fade in beneath it (fade only — no slide).
        at(1.9) { withAnimation(SplashMotion.easeOut(0.6)) { wordmarkOpacity = 1 } }

        // Once drawn, the pupil starts breathing.
        at(2.0) { isPulsing = true }

        // Hold through a couple of breaths, then fade the mark out and hand off
        // to the tour (exit accelerates). The dark backdrop stays.
        at(4.4) { withAnimation(SplashMotion.easeIn(0.5)) { introOpacity = 0 } }
        at(5.0) { beginTour() }
    }

    /// After the intro mark fades: on first launch, hand off to the tour; on
    /// every later launch, just finish (the controller fades the backdrop out).
    private func beginTour() {
        guard showsTour else {
            onFinish()
            return
        }
        introRemoved = true
        showTour = true
        onTourBegan()
        withAnimation(SplashMotion.easeOut(0.5)) { tourOpacity = 1 }
    }

    /// Runs `work` on the main queue after `delay` seconds.
    private func at(_ delay: Double, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

// MARK: - Embedded tour

/// The feature tour, rendered inside the splash panel over the dark backdrop.
/// Reuses the slide content from `BlinkSlideshowDeck`; the last slide reveals a
/// Get Started button that ends the intro.
private struct BlinkStartupTour: View {
    let accent: Color
    let onGetStarted: () -> Void

    private let slides = BlinkSlideshowDeck.slides
    @State private var index = 0
    @FocusState private var focused: Bool

    private var isLast: Bool { index == slides.count - 1 }

    var body: some View {
        ZStack {
            // Persistent brand lockup — a small breathing orb + wordmark pinned
            // to the corner, carrying the intro's identity through the tour and
            // anchoring the otherwise-empty top-left.
            brandLockup
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(36)

            VStack(spacing: 34) {
                slideContent(slides[index])
                    .id(index)
                    .transition(.opacity)

                VStack(spacing: 24) {
                    HStack(spacing: 16) {
                        navButton("chevron.left", disabled: index == 0) { go(-1) }
                        dots
                        navButton("chevron.right", disabled: isLast) { go(1) }
                    }

                    if isLast {
                        Button("Get Started", action: onGetStarted)
                            .dsPrimaryButtonStyle(isFullWidth: false)
                            .transition(.opacity)
                    }
                }
            }
            .frame(maxWidth: 620)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .focusable()
        .focused($focused)
        // Keep key-handling, but suppress the system focus ring — its blue
        // rounded outline boxes the focusable region, not the content.
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow)  { go(-1); return .handled }
        .onKeyPress(.rightArrow) { go(1);  return .handled }
        .onKeyPress(.space)      { go(1);  return .handled }
        .onKeyPress(.escape)     { onGetStarted(); return .handled }
    }

    private var brandLockup: some View {
        HStack(spacing: 11) {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                let breath = (sin(context.date.timeIntervalSinceReferenceDate * (2 * .pi / 1.6)) + 1) / 2
                Circle()
                    .fill(accent)
                    .frame(width: 13, height: 13)
                    .scaleEffect(1 + 0.18 * CGFloat(breath))
                    .shadow(color: accent.opacity(0.6), radius: 6)
            }
            .frame(width: 20, height: 20)

            Text("Blink")
                .font(.system(size: 17, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(DS.Colors.textPrimary)
        }
    }

    private func slideContent(_ slide: BlinkSlide) -> some View {
        VStack(spacing: 28) {
            Image(systemName: slide.symbolName)
                .font(.system(size: 58, weight: .regular))
                .foregroundStyle(slide.symbolHue.color(accent: accent))
                .frame(width: 116, height: 116)
                .background(Circle().fill(slide.symbolHue.color(accent: accent).opacity(0.12)))

            VStack(spacing: 14) {
                Text(slide.title)
                    .font(.system(size: 36, weight: .semibold))
                    .tracking(-0.9)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .multilineTextAlignment(.center)

                Text(slide.body)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
                    .frame(maxWidth: 600)
            }
        }
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(slides.indices, id: \.self) { i in
                Capsule()
                    .fill(i == index ? accent : DS.Colors.textTertiary.opacity(0.5))
                    .frame(width: i == index ? 22 : 8, height: 8)
                    .contentShape(Capsule())
                    .onTapGesture { withAnimation(SplashMotion.easeOut(0.3)) { index = i } }
            }
        }
    }

    private func navButton(_ symbol: String, disabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
        }
        .dsIconButtonStyle(size: 36)
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1)
    }

    private func go(_ delta: Int) {
        let next = index + delta
        guard next >= 0, next < slides.count else { return }
        withAnimation(SplashMotion.easeOut(0.35)) { index = next }
    }
}

// MARK: - Listening Indicator

/// A scaled-up replica of the cursor's push-to-talk listening indicator. The
/// ring strokes itself on (driven by `drawProgress`), and once `isPulsing` is
/// set the pupil dilates and contracts on the same 1.6s breath cycle the real
/// overlay uses. There's no live audio at launch, so the pupil breathes on its
/// own instead of reacting to amplitude.
private struct BlinkListeningIndicator: View {
    var drawProgress: CGFloat
    var isPulsing: Bool
    let color: Color

    var body: some View {
        ZStack {
            // Ring: animated by the parent from 0 → full, starting at the top.
            Circle()
                .trim(from: 0, to: drawProgress)
                .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 150, height: 150)
                .shadow(color: color.opacity(0.45), radius: 12)

            // Pupil: fades in as the ring finishes, then breathes. The breath
            // is a `scaleEffect` (transform) on a fixed-size circle, never an
            // animated frame size — animate transform/opacity only (Hallmark
            // motion.md, slop-test gate 15).
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                let breath = isPulsing
                    ? (sin(context.date.timeIntervalSinceReferenceDate * (2 * .pi / 1.6)) + 1) / 2
                    : 0
                let pulse = 1 + 0.3 * CGFloat(breath)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [color, color.opacity(0.4)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 26
                        )
                    )
                    .frame(width: 52, height: 52)
                    .scaleEffect(pulse)
                    .shadow(color: color.opacity(0.6), radius: 18)
            }
            .opacity(Double(min(max((drawProgress - 0.6) / 0.4, 0), 1)))
        }
        .frame(width: 150, height: 150)
    }
}
