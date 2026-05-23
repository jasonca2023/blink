import SwiftUI
import AppKit

/// Static "working" affordance while the agent has not produced its
/// first streamed token yet. Replaces the previous pulsing-dots
/// animation so subagent surfaces stay calm.
struct BlinkThinkingDots: View {
    let tint: Color

    var body: some View {
        Text("Working")
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(tint.opacity(0.85))
            .padding(.vertical, 4)
    }
}

struct BlinkAgentDockHoverCard: View {
    let item: BlinkAgentDockItem
    let canOpenDashboard: Bool
    let chat: () -> Void
    let text: () -> Void
    let voice: () -> Void
    let close: () -> Void
    let stop: () -> Void
    /// Called when the user taps "Dismiss" on a terminal (`.done`/`.failed`)
    /// agent. Distinct from `stop` (which sends a cancel signal) — this
    /// just removes the dock item visually.
    let dismiss: () -> Void
    let runSuggestedAction: (String) -> Void
    @State private var isConfirmingStop = false
    @State private var hoveredQuickAction: QuickAction? = nil
    @State private var statusLineCycleIndex = 0
    @State private var statusLineCycleTask: Task<Void, Never>?
    private static let agentProgressBottomID = "agent-progress-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(sentenceCasedTitle(displayTitle))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 4) {
                    Image(systemName: statusSymbolName)
                        .font(.system(size: 10, weight: .semibold))
                    Text(statusText)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(titleAccentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(titleAccentColor.opacity(0.14)))

                Spacer()
            }
            .padding(.trailing, 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.progressStageLabel)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)

                if let statusLine = currentStatusLine {
                    Text(statusLine)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                } else {
                    Text(" ")
                        .font(.system(size: 12, weight: .regular))
                        .lineLimit(2)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 38, alignment: .topLeading)
            .padding(.top, 4)

            agentProgressContent
                .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58, alignment: .topLeading)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 8) {
                if hasTaskActionButtons {
                    HStack(spacing: 8) {
                        ForEach(item.suggestedNextActions, id: \.self) { actionTitle in
                            Button(action: {
                                runSuggestedAction(actionTitle)
                            }) {
                                Text(actionTitle)
                            }
                            .buttonStyle(BlinkAgentDockPillButtonStyle())
                        }

                        if let linkTarget {
                            Button {
                                NSWorkspace.shared.open(linkTarget)
                            } label: {
                                Label(linkButtonTitle(for: linkTarget), systemImage: "arrow.up.right.square")
                            }
                            .buttonStyle(BlinkAgentDockPillButtonStyle())
                        }
                    }
                    .frame(height: 28, alignment: .leading)
                } else {
                    Color.clear
                        .frame(height: 28)
                }

                bottomActionRow
            }
            .padding(.top, 12)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .heavy))
            }
            .buttonStyle(BlinkAgentGlassCloseButtonStyle())
            .help("Close")
            .offset(x: 13, y: -3)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 500, height: 236, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
        .background(
            .thickMaterial,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.42), radius: 24, x: 0, y: 16)
        .onAppear { restartStatusLineCycle() }
        .onDisappear {
            statusLineCycleTask?.cancel()
            statusLineCycleTask = nil
        }
        .onChange(of: item.activityStatusLines) { _, _ in
            restartStatusLineCycle()
        }
        .onChange(of: item.progressStepText ?? "") { _, _ in
            restartStatusLineCycle()
        }
        .onChange(of: item.status) { _, _ in
            restartStatusLineCycle()
        }
    }

    @ViewBuilder
    private var agentProgressContent: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    if let trimmedCaption,
                       !trimmedCaption.isEmpty {
                        Text(trimmedCaption)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // No real activity yet — surface a thinking indicator
                        // instead of the canned "An agent is working on this." line.
                        switch item.status {
                        case .starting, .running:
                            BlinkThinkingDots(tint: item.accentTheme.cursorColor)
                        case .done:
                            Text("Done.")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(item.accentTheme.cursorColor)
                        case .failed:
                            Text("Stopped.")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(Color.primary)
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.agentProgressBottomID)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.vertical, 8)
            }
            .mask(BlinkAgentProgressScrollFadeMask())
            .onAppear { scrollAgentProgressToBottom(proxy, animated: false) }
            .onChange(of: agentProgressScrollKey) { _, _ in
                scrollAgentProgressToBottom(proxy, animated: true)
            }
        }
    }


    private var agentProgressScrollKey: String {
        [
            trimmedCaption ?? "",
            currentStatusLine ?? "",
            statusText
        ].joined(separator: "\u{1F}")
    }

    private func scrollAgentProgressToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            let action = {
                proxy.scrollTo(Self.agentProgressBottomID, anchor: .bottom)
            }
            if animated {
                withAnimation(.easeOut(duration: 0.18), action)
            } else {
                action()
            }
        }
    }

    private var trimmedCaption: String? {
        guard let trimmed = item.caption?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        if lowered == "checking the work" || lowered == "check the work" {
            return nil
        }
        return trimmed
    }

    private var statusLineLabel: String {
        if isTerminalStatus { return "Final" }
        return activityStatusLines.count > 1 ? "Update" : "Step"
    }

    private var currentStatusLine: String? {
        let lines = activityStatusLines
        guard !lines.isEmpty else { return nil }
        if isTerminalStatus {
            return lines.last
        }
        let safeIndex = min(statusLineCycleIndex, lines.count - 1)
        return lines[safeIndex]
    }

    private var isTerminalStatus: Bool {
        item.status == .done || item.status == .failed
    }

    private var activityStatusLines: [String] {
        var lines: [String] = []
        for candidate in item.activityStatusLines + [item.progressStepText ?? ""] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if lines.last != trimmed {
                lines.append(trimmed)
            }
        }
        return lines
    }

    private func restartStatusLineCycle() {
        statusLineCycleTask?.cancel()
        statusLineCycleTask = nil
        let lines = activityStatusLines
        statusLineCycleIndex = isTerminalStatus ? max(lines.count - 1, 0) : 0
        guard !isTerminalStatus else { return }
        guard lines.count > 1 else { return }

        statusLineCycleTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_900_000_000)
                if Task.isCancelled { return }
                let count = activityStatusLines.count
                guard count > 1 else { continue }
                withAnimation(.easeInOut(duration: 0.18)) {
                    statusLineCycleIndex = (statusLineCycleIndex + 1) % count
                }
            }
        }
    }

    private var bottomActionRow: some View {
        HStack(spacing: 8) {
            quickActionButtons
            Spacer(minLength: 12)
            terminalActionButton
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .center)
    }

    private var quickActionButtons: some View {
        HStack(spacing: 8) {
            HoverExpandIconActionButton(icon: "mic", label: "Voice", isExpanded: hoveredQuickAction == .voice, action: voice)
                .onHover { hoveredQuickAction = $0 ? .voice : nil }
            HoverExpandIconActionButton(icon: "text.cursor", label: "Text", isExpanded: hoveredQuickAction == .text, action: text)
                .onHover { hoveredQuickAction = $0 ? .text : nil }
            if canOpenDashboard {
                HoverExpandIconActionButton(icon: "message", label: "Chat", isExpanded: hoveredQuickAction == .dashboard, action: chat)
                    .onHover { hoveredQuickAction = $0 ? .dashboard : nil }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var terminalActionButton: some View {
        if item.status == .starting || item.status == .running {
            Button {
                isConfirmingStop = true
            } label: {
                Image(systemName: "stop.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14, height: 14)
            }
            .accessibilityLabel("Stop")
            .help("Stop")
            .buttonStyle(BlinkAgentDockStopButtonStyle(isConfirming: false))
            .confirmationDialog("Stop this agent?", isPresented: $isConfirmingStop, titleVisibility: .visible) {
                Button("Stop", role: .destructive, action: stop)
                Button("Keep running", role: .cancel) {}
            }
        } else if item.status == .done || item.status == .failed {
            Button(action: dismiss) {
                Image(systemName: "archivebox")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14, height: 14)
            }
            .accessibilityLabel("Archive")
            .help("Archive")
                .buttonStyle(BlinkAgentDockPillButtonStyle())
        }
    }

    private enum QuickAction { case voice, text, dashboard }

    private var hasTaskActionButtons: Bool {
        !item.suggestedNextActions.isEmpty || linkTarget != nil
    }

    private var linkTarget: URL? {
        // Only scan the live caption — the previous version scanned the
        // canned "An agent is working on this." fallback, which never
        // contained a link anyway.
        Self.firstOpenableURL(in: item.caption ?? "")
    }

    private func linkButtonTitle(for url: URL) -> String {
        url.isFileURL ? "Open \(url.lastPathComponent)" : "Open link"
    }

    private static func firstOpenableURL(in text: String) -> URL? {
        let patterns = [
            #"`((?:file://)?/[^`]+)`"#,
            #"((?:file://)?/Users/[^\s`]+)"#,
            #"(https?://[^\s`]+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
                  let matchRange = Range(match.range(at: 1), in: text) else { continue }
            let raw = String(text[matchRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: "`'\".,)\n\t "))
            if raw.hasPrefix("file://"), let url = URL(string: raw) {
                return url
            }
            if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
                return URL(string: raw)
            }
            if raw.hasPrefix("/") {
                return URL(fileURLWithPath: raw)
            }
        }
        return nil
    }

    private var displayTitle: String {
        let trimmedTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? "Hey there" : trimmedTitle
    }

    /// Converts ALL-CAPS or oddly cased titles into a single-capital
    /// "Sentence case" form so the card reads like a native Apple label.
    private func sentenceCasedTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let isAllCaps = trimmed == trimmed.uppercased() && trimmed.rangeOfCharacter(from: .letters) != nil
        let normalized = isAllCaps ? trimmed.lowercased() : trimmed
        return normalized.prefix(1).uppercased() + normalized.dropFirst()
    }

    private var statusText: String {
        switch item.status {
        case .starting:
            return "Starting"
        case .running:
            return "Running"
        case .done:
            return "Done"
        case .failed:
            return "Failed"
        }
    }

    private var statusSymbolName: String {
        switch item.status {
        case .starting, .running:
            return "ellipsis"
        case .done:
            return "checkmark"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var titleAccentColor: Color {
        item.accentTheme.cursorColor.opacity(0.95)
    }

    private var statusBackgroundColor: Color {
        item.accentTheme.cursorColor.opacity(0.18)
    }

}

private struct BlinkAgentProgressScrollFadeMask: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .black, location: 0.055),
                .init(color: .black, location: 0.945),
                .init(color: .clear, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

struct BlinkAgentGlassCloseButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(DS.Colors.textPrimary.opacity(isHovered ? 1.0 : 0.82))
            .frame(width: 30, height: 30)
            .background(.thickMaterial, in: Circle())
            .background(
                Circle()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.18 : (isHovered ? 0.14 : 0.08)))
            )
            .overlay(
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(isHovered ? 0.42 : 0.28), Color.white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.22), radius: 8, x: 0, y: 4)
            .scaleEffect(configuration.isPressed ? 0.94 : (isHovered ? 1.04 : 1.0))
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .pointerCursor()
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

struct HoverExpandIconActionButton: View {
    let icon: String
    let label: String
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                if isExpanded { Text(label) }
            }
        }
        .buttonStyle(BlinkAgentDockPillButtonStyle())
    }
}

struct BlinkAgentDockStopButtonStyle: ButtonStyle {
    let isConfirming: Bool
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(isConfirming ? Color.white : Color(hex: "#FFB4BA"))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isConfirming ? Color(hex: "#B91C1C").opacity(configuration.isPressed ? 0.95 : 0.82) : Color(hex: "#7F1D1D").opacity(isHovered ? 0.38 : 0.22))
            )
            .overlay(
                Capsule()
                    .stroke(Color(hex: "#FF6369").opacity(isHovered || isConfirming ? 0.50 : 0.28), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .pointerCursor()
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

struct BlinkAgentDockPillButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(DS.Colors.textPrimary)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.18 : (isHovered ? 0.14 : 0.10)))
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(isHovered ? 0.24 : 0.14), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .pointerCursor()
            .onHover { hovering in
                isHovered = hovering
            }
    }
}
