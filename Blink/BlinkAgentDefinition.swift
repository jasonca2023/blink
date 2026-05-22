//
//  BlinkAgentDefinition.swift
//  Blink
//
//  Specialist agent definition (openclaw-style). Agents live on disk in
//  one of two roots:
//
//    Built-ins (read-only, ships with the app):
//      <App Support>/Blink/agents/<slug>/
//    User (writable, overrides a built-in by slug match per file):
//      ~/.blink/agents/<slug>/
//
//  Per-agent files (all optional, missing → default):
//    agent.json        metadata (displayName, description, accentColorHex)
//    soul.md           persona / identity text
//    instructions.md   task instructions
//    memory.md         agent-scoped persistent memory
//    skills.json       { "enabledSkillIDs": [...] } flat enable list
//    skills/           custom skills (auto-enabled, each in its own subdir)
//    tools/            custom tools
//

import Foundation

struct BlinkAgentMetadata: Codable, Equatable {
  var displayName: String
  var description: String
  var accentColorHex: String?
  var schemaVersion: Int = 1

  init(displayName: String, description: String = "", accentColorHex: String? = nil, schemaVersion: Int = 1) {
    self.displayName = displayName
    self.description = description
    self.accentColorHex = accentColorHex
    self.schemaVersion = schemaVersion
  }
}

struct BlinkAgentSkillSelection: Codable, Equatable {
  var enabledSkillIDs: [String]

  init(enabledSkillIDs: [String] = []) {
    self.enabledSkillIDs = enabledSkillIDs
  }
}

/// A resolved agent ready for use. `directory` is the *effective* root —
/// for an agent that exists in both roots, this points at the user root
/// (which wins). Per-file resolution still re-checks both roots so the
/// user can override individual files (e.g. only soul.md).
struct BlinkAgentDefinition: Identifiable, Equatable {
  let slug: String
  let metadata: BlinkAgentMetadata
  let soul: String
  let instructions: String
  let memory: String
  let heartbeat: String
  let skills: BlinkAgentSkillSelection
  let isUserDefined: Bool
  let userDirectory: URL
  let builtinDirectory: URL?

  var id: String { slug }
  var isProtectedSystemAgent: Bool { slug == BlinkAgentStore.skillDiscoveryAgentSlug }

  /// String Blink prepends to the Codex Agent Mode system prompt
  /// when a session launches under this agent. Includes the on-disk paths
  /// to the agent's custom skills/tools directories and HEARTBEAT.md so
  /// Codex can read/update them on demand.
  func renderedSystemContext() -> String {
    var parts: [String] = []
    parts.append("You are operating as the \"\(metadata.displayName)\" specialist Blink agent (slug: \(slug)).")
    if !metadata.description.isEmpty {
      parts.append(metadata.description)
    }
    if !soul.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      parts.append("--- Agent soul ---\n\(soul)")
    }
    if !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      parts.append("--- Agent instructions ---\n\(instructions)")
    }
    if !memory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      parts.append("--- Agent memory ---\n\(memory)")
    }
    if !heartbeat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      parts.append("--- Agent HEARTBEAT (read at start, tick off completed items, update Last check-in) ---\n\(heartbeat)")
    }
    if !skills.enabledSkillIDs.isEmpty {
      parts.append("--- Agent enabled skills (filenames in your custom skills dir or inherited) ---\n" + skills.enabledSkillIDs.joined(separator: ", "))
    }
    // Resolve effective paths so the runtime can read/write directly.
    var pathLines: [String] = []
    let effectiveDir = (isUserDefined ? userDirectory : (builtinDirectory ?? userDirectory))
    pathLines.append("- Agent root: \(effectiveDir.path)")
    pathLines.append("- soul.md: \(effectiveDir.appendingPathComponent("soul.md").path)")
    pathLines.append("- instructions.md: \(effectiveDir.appendingPathComponent("instructions.md").path)")
    pathLines.append("- memory.md: \(effectiveDir.appendingPathComponent("memory.md").path)")
    pathLines.append("- HEARTBEAT.md: \(effectiveDir.appendingPathComponent("HEARTBEAT.md").path)")
    pathLines.append("- skills/: \(effectiveDir.appendingPathComponent("skills").path)")
    pathLines.append("- tools/: \(effectiveDir.appendingPathComponent("tools").path)")
    parts.append("--- Agent on-disk paths ---\n" + pathLines.joined(separator: "\n"))
    return parts.joined(separator: "\n\n")
  }

  // MARK: read

  /// Per-file resolver: user root wins for every file individually.
  static func load(slug: String, userRoot: URL, builtinRoot: URL) -> BlinkAgentDefinition? {
    let userDir = userRoot.appendingPathComponent(slug, isDirectory: true)
    let builtinDir = builtinRoot.appendingPathComponent(slug, isDirectory: true)
    let userExists = FileManager.default.fileExists(atPath: userDir.path)
    let builtinExists = FileManager.default.fileExists(atPath: builtinDir.path)
    guard userExists || builtinExists else { return nil }

    func read(_ name: String) -> String {
      let userURL = userDir.appendingPathComponent(name)
      if let s = try? String(contentsOf: userURL, encoding: .utf8) { return s }
      let bURL = builtinDir.appendingPathComponent(name)
      if let s = try? String(contentsOf: bURL, encoding: .utf8) { return s }
      return ""
    }

    let metadata: BlinkAgentMetadata = {
      let userMeta = userDir.appendingPathComponent("agent.json")
      let builtinMeta = builtinDir.appendingPathComponent("agent.json")
      let decoder = JSONDecoder()
      if let data = try? Data(contentsOf: userMeta),
         let m = try? decoder.decode(BlinkAgentMetadata.self, from: data) { return m }
      if let data = try? Data(contentsOf: builtinMeta),
         let m = try? decoder.decode(BlinkAgentMetadata.self, from: data) { return m }
      return BlinkAgentMetadata(displayName: slug.capitalized)
    }()

    let skills: BlinkAgentSkillSelection = {
      let userSkills = userDir.appendingPathComponent("skills.json")
      let builtinSkills = builtinDir.appendingPathComponent("skills.json")
      let decoder = JSONDecoder()
      if let data = try? Data(contentsOf: userSkills),
         let s = try? decoder.decode(BlinkAgentSkillSelection.self, from: data) { return s }
      if let data = try? Data(contentsOf: builtinSkills),
         let s = try? decoder.decode(BlinkAgentSkillSelection.self, from: data) { return s }
      return BlinkAgentSkillSelection()
    }()

    return BlinkAgentDefinition(
      slug: slug,
      metadata: metadata,
      soul: read("soul.md"),
      instructions: read("instructions.md"),
      memory: read("memory.md"),
      heartbeat: read("HEARTBEAT.md"),
      skills: skills,
      isUserDefined: userExists,
      userDirectory: userDir,
      builtinDirectory: builtinExists ? builtinDir : nil
    )
  }

  // MARK: write (user root only — built-ins are read-only)

  static func write(slug: String, in userRoot: URL, metadata: BlinkAgentMetadata, soul: String, instructions: String, memory: String, heartbeat: String, skills: BlinkAgentSkillSelection) throws {
    let dir = userRoot.appendingPathComponent(slug, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("skills"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("tools"), withIntermediateDirectories: true)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    try encoder.encode(metadata).write(to: dir.appendingPathComponent("agent.json"))
    try soul.write(to: dir.appendingPathComponent("soul.md"), atomically: true, encoding: .utf8)
    try instructions.write(to: dir.appendingPathComponent("instructions.md"), atomically: true, encoding: .utf8)
    try memory.write(to: dir.appendingPathComponent("memory.md"), atomically: true, encoding: .utf8)
    try heartbeat.write(to: dir.appendingPathComponent("HEARTBEAT.md"), atomically: true, encoding: .utf8)
    try encoder.encode(skills).write(to: dir.appendingPathComponent("skills.json"))
  }
}
