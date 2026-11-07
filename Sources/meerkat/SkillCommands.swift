import ArgumentParser
import Foundation
import MeerkatKit

// MARK: - skills

struct Skills: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Instructions for coding agents on using Meerkat, as agent skills.",
        discussion: "The same text is served as MCP prompts by `meerkat mcp`.",
        subcommands: [List.self, Show.self, Install.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand, JSONOutput {
        static let configuration = CommandConfiguration(abstract: "The skills this build has.")
        @Flag(help: "Print JSON.") var json = false

        struct Entry: Encodable {
            let name: String
            let title: String
            let summary: String
        }

        func run() throws {
            if json {
                return try printJSON(
                    AgentSkill.all.map { Entry(name: $0.name, title: $0.title, summary: $0.summary) }, pretty: true)
            }
            for skill in AgentSkill.all { print("\(skill.name)  \(skill.summary)") }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print a skill's SKILL.md.")
        @Argument(help: "Skill name.") var name: String

        func run() throws {
            print(try Skills.named([name])[0].document, terminator: "")
        }
    }

    struct Install: ParsableCommand, JSONOutput {
        static let configuration = CommandConfiguration(
            abstract: "Write skills into an agent's skills folder.",
            discussion: """
                Writes <folder>/<name>/SKILL.md. Run it again after upgrading Meerkat. Exits 1, writing \
                nothing, if a skill there has other text, unless --force.
                """
        )

        @Option(help: "The agent's skills folder, like ~/.claude/skills or ~/.agents/skills.") var to: String
        @Argument(help: "Skills to install; all of them when omitted.") var names: [String] = []
        @Flag(help: "Replace skills that have other text.") var force = false
        @Flag(help: "Print the files written as a JSON array.") var json = false

        func run() throws {
            let folder = URL(fileURLWithPath: (to as NSString).expandingTildeInPath)
            let skills = names.isEmpty ? AgentSkill.all : try Skills.named(names)
            let files: [URL]
            do {
                files = try Skills.install(skills, into: folder, force: force)
            } catch let conflict as Conflict {
                throw CommandFailure("\(conflict)")
            }
            if json { return try printJSON(files.map(\.path), pretty: true) }
            for file in files { print(file.path) }
        }
    }

    struct Conflict: Error, CustomStringConvertible {
        let file: URL
        var description: String { "\(file.path) has other text; --force replaces it" }
    }

    static func named(_ names: [String]) throws -> [AgentSkill] {
        try names.map { name in
            guard let skill = AgentSkill.named(name) else {
                let known = AgentSkill.all.map(\.name).joined(separator: ", ")
                throw ValidationError("no skill named \(name); there are \(known)")
            }
            return skill
        }
    }

    /// Writes each skill's file and returns them. Every file is checked
    /// before any is written, so a conflict leaves the folder as it was.
    /// Only a missing file is absent: one that isn't this text, including
    /// one that isn't UTF-8, is a conflict, and one that can't be read stops
    /// the install, so nothing the user wrote is replaced unseen.
    static func install(_ skills: [AgentSkill], into folder: URL, force: Bool) throws -> [URL] {
        let files = skills.map { (skill: $0, file: folder.appendingPathComponent("\($0.name)/SKILL.md")) }
        if !force {
            for (skill, file) in files {
                let existing: Data
                do {
                    existing = try Data(contentsOf: file)
                } catch CocoaError.fileReadNoSuchFile {
                    continue
                }
                if existing != Data(skill.document.utf8) { throw Conflict(file: file) }
            }
        }
        for (skill, file) in files {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try skill.document.write(to: file, atomically: true, encoding: .utf8)
        }
        return files.map(\.file)
    }
}
