//
//  BlinkRichResponseWindowManager.swift
//  Blink
//
//  Centered translucent "showcase" panel that surfaces Blink's spoken
//  response with a large topical image fetched from Unsplash's free
//  Source API. Designed to feel like a visual answer card: the user
//  asks "what's the weather in Tokyo" → a Tokyo photo + the response
//  text fades up in the centre of the screen while the system voice
//  speaks the answer.
//

import AppKit
import SwiftUI

@MainActor
final class BlinkRichResponseWindowManager {
    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?
    private let autoDismissAfter: TimeInterval = 12.0

    /// Shows (or replaces) the showcase panel. `transcript` is what the
    /// user said — used as the image-search query. `responseText` is what
    /// the model said back and is rendered as the main copy.
    func show(transcript: String, responseText: String) {
        let trimmedResponse = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResponse.isEmpty else { return }

        guard let screen = NSScreen.main else { return }
        let size = NSSize(width: 640, height: 480)
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2
        )
        let frame = NSRect(origin: origin, size: size)

        let imageQuery = Self.imageQuery(forTranscript: transcript, fallbackResponse: trimmedResponse)

        let existingPanel = panel
        let panel: NSPanel = existingPanel ?? {
            let newPanel = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            newPanel.isFloatingPanel = true
            newPanel.level = .floating
            newPanel.hasShadow = true
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.titlebarAppearsTransparent = true
            newPanel.titleVisibility = .hidden
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            newPanel.alphaValue = 0
            return newPanel
        }()

        let rootView = BlinkRichResponseRootView(
            responseText: trimmedResponse,
            imageQuery: imageQuery,
            onDismiss: { [weak self] in self?.hide() }
        )
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.setFrame(frame, display: true)

        if existingPanel == nil {
            self.panel = panel
            panel.orderFront(nil)
        } else {
            panel.orderFront(nil)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        }

        scheduleAutoDismiss()
    }

    func hide() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.28
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                panel.orderOut(nil)
                self?.panel = nil
            }
        })
    }

    private func scheduleAutoDismiss() {
        dismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in self?.hide() }
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + autoDismissAfter, execute: workItem)
    }

    /// Picks a 3-5 word image search query from the user's transcript by
    /// stripping question words and verb fillers. Falls back to the first
    /// few words of the response if the transcript is empty.
    private static func imageQuery(forTranscript transcript: String, fallbackResponse: String) -> String {
        let basis = transcript.isEmpty ? fallbackResponse : transcript
        let lowered = basis.lowercased()
        let stripped = lowered.replacingOccurrences(
            of: #"\b(?:what(?:'s)?|whats|who(?:'s)?|where(?:'s)?|when(?:'s)?|why|how|is|are|am|the|a|an|on|in|at|of|for|to|me|please|can|could|would|will|do|does|did|tell|show|find|look|up|tell|me|about|going|today|now|right|currently)\b"#,
            with: "",
            options: .regularExpression
        )
        let collapsed = stripped.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: CharacterSet(charactersIn: " ?.,!:;\n\t"))
        let words = collapsed.split(separator: " ").prefix(5).joined(separator: " ")
        return words.isEmpty ? "abstract" : words
    }
}

private struct BlinkRichResponseRootView: View {
    let responseText: String
    let imageQuery: String
    let onDismiss: () -> Void

    @State private var image: NSImage?
    @State private var imageFailed: Bool = false
    @State private var appear: Bool = false

    var body: some View {
        ZStack {
            // Liquid-glass-ish translucent background
            VisualEffectBackground()
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

            VStack(alignment: .leading, spacing: 0) {
                imageHeader
                contentBody
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.55), radius: 38, x: 0, y: 18)
        .opacity(appear ? 1 : 0)
        .scaleEffect(appear ? 1 : 0.96)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: appear)
        .onAppear {
            appear = true
            Task { await loadImage() }
        }
        .onTapGesture { onDismiss() }
    }

    @ViewBuilder
    private var imageHeader: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 260)
                    .clipped()
                    .overlay(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.0),
                                Color.black.opacity(0.55)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            } else {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.10, green: 0.12, blue: 0.20),
                                Color(red: 0.05, green: 0.06, blue: 0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 260)
                    .overlay(
                        VStack(spacing: 10) {
                            if imageFailed {
                                Image(systemName: "photo")
                                    .font(.system(size: 30, weight: .light))
                                    .foregroundStyle(.white.opacity(0.35))
                                Text("Blink")
                                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.55))
                            } else {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .controlSize(.large)
                                    .tint(.white.opacity(0.85))
                            }
                        }
                    )
            }
            VStack {
                Spacer()
                HStack {
                    Text(imageQuery.capitalized)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.black.opacity(0.42))
                        )
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(responseText)
                .font(.system(size: 17, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
                .lineSpacing(4)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Text("tap to dismiss")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .textCase(.uppercase)
                    .tracking(1.6)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 18)
    }

    private func loadImage() async {
        let trimmedQuery = imageQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: ",")
        guard !trimmedQuery.isEmpty else {
            imageFailed = true
            return
        }
        guard let encoded = trimmedQuery.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://source.unsplash.com/featured/800x500/?\(encoded)") else {
            imageFailed = true
            return
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            request.setValue("Blink/1.0", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            if let loaded = NSImage(data: data) {
                self.image = loaded
            } else {
                self.imageFailed = true
            }
        } catch {
            self.imageFailed = true
        }
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
