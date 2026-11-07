import ArgumentParser
import Foundation
import ReleaseVersion
import ToolProcess

// Decides whether this commit publishes a release (ReleasePlan), for the
// release job in .github/workflows/ci.yml:
//
//   buck2 run //Tools/Release:plan >> "$GITHUB_OUTPUT"
//
// It prints `publish`, `version`, `tag` and `prerelease` as key=value lines
// on stdout and fails when the declared version is not a release version or
// precedes the latest release. Tags are read from the checkout, so it needs
// them fetched (`fetch-depth: 0`).

@main
struct Release: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release",
        abstract: "Decide whether the declared version is published.",
        subcommands: [Plan.self]
    )
}

struct Plan: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print whether the declared version has a release yet, as key=value lines."
    )

    @Option(help: "The declared version ([meerkat] version in .buckconfig).", transform: SemanticVersion.init)
    var version: SemanticVersion

    func run() throws {
        let tags = try Subprocess("/usr/bin/git", ["tag", "--list", "v*"]).output()
            .split(separator: "\n").map(String.init)
        let plan = try ReleasePlan(version: version, tags: tags)
        let publish: Bool
        switch plan {
        case .publish: publish = true
        case .alreadyReleased:
            publish = false
            FileHandle.standardError.write(Data("\(version.tag) is already released; nothing to publish\n".utf8))
        }
        print(
            """
            publish=\(publish)
            version=\(version)
            tag=\(version.tag)
            prerelease=\(version.isPrerelease)
            """)
    }
}
