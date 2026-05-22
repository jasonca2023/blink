import SwiftUI

struct BlinkPromptAutocompleteOption: Identifiable, Equatable {
  enum Trigger: String {
    case slash = "/"
    case mention = "@"
  }

  let id: String
  let trigger: Trigger
  let title: String
  let subtitle: String
  let completion: String
  let systemImage: String
}

enum BlinkPromptAutocomplete {
  private struct Context {
    let trigger: BlinkPromptAutocompleteOption.Trigger
    let query: String
  }

  static func options(
    for text: String,
    agents: [BlinkAgentDefinition],
    skillSuggestions: [BlinkSkillDiscoverySuggestion]
  ) -> [BlinkPromptAutocompleteOption] {
    guard let context = context(for: text) else { return [] }

    let baseOptions: [BlinkPromptAutocompleteOption]
    switch context.trigger {
    case .slash:
      baseOptions = slashOptions
    case .mention:
      baseOptions = mentionOptions(agents: agents, skillSuggestions: skillSuggestions)
    }

    let query = context.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let filtered = query.isEmpty ? baseOptions : baseOptions.filter { option in
      option.title.lowercased().contains(query)
        || option.subtitle.lowercased().contains(query)
        || option.completion.lowercased().contains(query)
    }
    return filtered
  }

  @discardableResult
  static func acceptFirstOption(
    in text: inout String,
    agents: [BlinkAgentDefinition],
    skillSuggestions: [BlinkSkillDiscoverySuggestion]
  ) -> Bool {
    guard let option = options(for: text, agents: agents, skillSuggestions: skillSuggestions).first else {
      return false
    }
    apply(option, to: &text)
    return true
  }

  static func apply(_ option: BlinkPromptAutocompleteOption, to text: inout String) {
    guard let range = activeTokenRange(in: text) else { return }
    let suffix = text[range.upperBound...]
    let needsSpace = suffix.first.map { !$0.isWhitespace } ?? true
    text.replaceSubrange(range, with: option.completion + (needsSpace ? " " : ""))
  }

  private static func context(for text: String) -> Context? {
    guard let range = activeTokenRange(in: text) else { return nil }
    let token = String(text[range])
    guard let first = token.first else { return nil }
    switch first {
    case "/":
      return Context(trigger: .slash, query: String(token.dropFirst()))
    case "@":
      return Context(trigger: .mention, query: String(token.dropFirst()))
    default:
      return nil
    }
  }

  private static func activeTokenRange(in text: String) -> Range<String.Index>? {
    guard !text.isEmpty else { return nil }
    var start = text.startIndex
    var index = text.startIndex
    while index < text.endIndex {
      if text[index].isWhitespace {
        start = text.index(after: index)
      }
      index = text.index(after: index)
    }
    guard start < text.endIndex else { return nil }
    return start..<text.endIndex
  }

  private static var slashOptions: [BlinkPromptAutocompleteOption] {
    [
      BlinkPromptAutocompleteOption(id: "slash-agent", trigger: .slash, title: "/agent", subtitle: "Start a background Blink agent task", completion: "/agent", systemImage: "bolt.fill"),
      BlinkPromptAutocompleteOption(id: "slash-chat", trigger: .slash, title: "/chat", subtitle: "Keep this in the Blink chat lane", completion: "/chat", systemImage: "bubble.left.and.bubble.right.fill"),
      BlinkPromptAutocompleteOption(id: "slash-ask", trigger: .slash, title: "/ask", subtitle: "Ask Blink with current context", completion: "/ask", systemImage: "sparkles"),
      BlinkPromptAutocompleteOption(id: "slash-screen", trigger: .slash, title: "/screen", subtitle: "Use current screen context", completion: "/screen", systemImage: "rectangle.dashed"),
      BlinkPromptAutocompleteOption(id: "slash-search", trigger: .slash, title: "/search", subtitle: "Search the web through Blink", completion: "/search", systemImage: "magnifyingglass"),
      BlinkPromptAutocompleteOption(id: "slash-3d", trigger: .slash, title: "/3d", subtitle: "Generate a 3D object preview", completion: "/3d", systemImage: "cube.fill"),
      BlinkPromptAutocompleteOption(id: "slash-gmail", trigger: .slash, title: "/gmail", subtitle: "Use Blink's gog Gmail workflow", completion: "/gmail", systemImage: "envelope.fill"),
      BlinkPromptAutocompleteOption(id: "slash-skill", trigger: .slash, title: "/skill", subtitle: "Ask Blink to use or install a skill", completion: "/skill", systemImage: "wrench.and.screwdriver.fill")
    ]
  }

  private static func mentionOptions(
    agents: [BlinkAgentDefinition],
    skillSuggestions: [BlinkSkillDiscoverySuggestion]
  ) -> [BlinkPromptAutocompleteOption] {
    let agentOptions = agents.map { agent in
      BlinkPromptAutocompleteOption(
        id: "agent-\(agent.slug)",
        trigger: .mention,
        title: "@\(agent.metadata.displayName)",
        subtitle: agent.metadata.description.isEmpty ? "Blink specialist" : agent.metadata.description,
        completion: "@\(agent.slug)",
        systemImage: "person.crop.circle.badge.checkmark"
      )
    }

    var seenSkillIDs = Set<String>()
    let skillOptions = skillSuggestions.compactMap { suggestion -> BlinkPromptAutocompleteOption? in
      let id = suggestion.id.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !id.isEmpty, !seenSkillIDs.contains(id.lowercased()) else { return nil }
      seenSkillIDs.insert(id.lowercased())
      return BlinkPromptAutocompleteOption(
        id: "skill-\(id)",
        trigger: .mention,
        title: "@\(suggestion.chipTitle ?? suggestion.title)",
        subtitle: "Skill · \(suggestion.detail)",
        completion: "@skill:\(id)",
        systemImage: suggestion.systemImage ?? "puzzlepiece.extension.fill"
      )
    }

    return agentOptions + skillOptions
  }
}

struct BlinkPromptAutocompletePanel: View {
  private static let visibleOptionLimit = 5
  private static let estimatedOptionHeight: CGFloat = 42
  private static let optionSpacing: CGFloat = 4
  private static let chromePadding: CGFloat = 10

  let options: [BlinkPromptAutocompleteOption]
  let select: (BlinkPromptAutocompleteOption) -> Void

  var body: some View {
    if !options.isEmpty {
      ScrollView {
        VStack(alignment: .leading, spacing: Self.optionSpacing) {
          ForEach(options) { option in
            Button {
              select(option)
            } label: {
              HStack(spacing: 8) {
                Image(systemName: option.systemImage)
                  .font(.system(size: 11, weight: .bold))
                  .foregroundColor(DS.Colors.accentText)
                  .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                  Text(option.title)
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                  Text(option.subtitle)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text("Tab")
                  .font(.system(size: 8, weight: .black, design: .rounded))
                  .foregroundColor(DS.Colors.textTertiary)
                  .padding(.horizontal, 5)
                  .padding(.vertical, 3)
                  .background(Capsule(style: .continuous).fill(Color.white.opacity(0.08)))
              }
              .padding(.horizontal, 9)
              .padding(.vertical, 7)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
          }
        }
      }
      .frame(maxHeight: maxPanelHeight)
      .padding(5)
      .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.Colors.surface1.opacity(0.98)))
      .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(DS.Colors.borderSubtle, lineWidth: 0.8))
      .shadow(color: Color.black.opacity(0.22), radius: 16, x: 0, y: 8)
    }
  }

  private var maxPanelHeight: CGFloat {
    let visibleCount = min(options.count, Self.visibleOptionLimit)
    let rows = CGFloat(visibleCount) * Self.estimatedOptionHeight
    let spacing = CGFloat(max(visibleCount - 1, 0)) * Self.optionSpacing
    return rows + spacing + Self.chromePadding
  }
}
