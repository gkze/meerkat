import ArgumentParser
import Foundation
import ToolProcess

// Builds a bundle on another Mac and assembles, signs and installs it here.
//
//   buck2 run //Tools/RemoteBuild:remote -- app-debug             # -> build/Meerkat.app
//   buck2 run //Tools/RemoteBuild:remote -- app --install         # also install
//   buck2 run -c remote_build.host=builder //Tools/RemoteBuild:remote -- app
//
// The host and the PATH it needs are this machine's settings, in
// .buckconfig.local (`[remote_build] host` and `path`).
//
// The build host gets this checkout (rsync, without Buck's output or Git),
// at the same path unless `[remote_build] directory` says otherwise, into a
// directory that is empty or this tool's earlier copy (`marker`), and
// runs `buck2 run //Tools/Bundler:<target>` there in `--command-args-file`
// mode, so Buck builds every part and reports the bundler command instead of
// running it. The parts that command names are copied back under
// build/remote/<target>/, and the bundler runs here, from the repository
// root, with those paths and this Mac's Xcode: signing needs this Mac's
// keychain identity, and installing is for this Mac.
//
// The host must build what this Mac would. The same buck2 (its prelude is
// bundled) is checked before anything is copied; the checkout's own toolchain
// tests, run there before anything is built, check the rest. Both they and
// the build there read this Mac's toolchain pins (`--pin`), not the host's
// .buckconfig.local, so a host override of a pin cannot pass the tests
// against itself.

/// A failure of the build, not of how the tool was invoked (which
/// ArgumentParser's ValidationError reports, with the usage).
struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@main
struct RemoteBuild: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remote_build",
        abstract: "Build a //Tools/Bundler bundle on another Mac; assemble, sign and install it here."
    )

    @Option(help: "The build host, as ssh names it (`[remote_build] host` in .buckconfig.local).")
    var host: String

    @Option(
        help:
            "Directories, colon-separated, put first on PATH on the host for buck2, python3 and rustup's rustc; `~/` is the host's home (`[remote_build] path`)."
    )
    var path = ""

    @Option(
        help:
            "The checkout's path on the host (`[remote_build] directory`; default: this checkout's path, which keeps paths in debug info the same)."
    )
    var directory = ""

    @Option(help: "Where the built parts are copied (default: build/remote).")
    var output: String?

    @Option(help: "This Mac's Xcode, for the bundler here (`[swift] developer_dir`).")
    var developerDir: String

    @Option(
        help:
            "A toolchain pin of this Mac's, `section.key=value`, that the host's tests and build read in place of its own configuration."
    )
    var pin: [String] = []

    @Argument(help: "The //Tools/Bundler target: app, app-debug or preview.")
    var target: String

    @Argument(
        parsing: .captureForPassthrough,
        help: "Arguments for the bundler, such as --install or --identity.")
    var bundlerArguments: [String] = []

    /// The tests that say a Mac builds what `.buckconfig` pins: its buck2,
    /// Python, Rust and Xcode.
    private static let toolchainTests = [
        "//buck2/rules:buck2_test", "//buck2/rules:python_test", "//buck2/rules:rust_test",
        "//buck2/rules/swift:xcode_test",
    ]

    /// The file that marks a directory on the host as this tool's copy of a
    /// checkout, written into an empty one on the first copy and kept by
    /// `rsync --delete` (it is excluded). A checkout's own files cannot mark
    /// it: any Buck repository has a `.buckroot`.
    private static let marker = ".meerkat-remote-build"

    /// The exit status of the host's check when the directory is neither.
    private static let notOurs: Int32 = 3

    func validate() throws {
        guard !host.isEmpty else {
            throw ValidationError(
                "no build host: set `[remote_build] host` in .buckconfig.local, or pass -c remote_build.host=<ssh host>"
            )
        }
        guard target.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }), !target.isEmpty else {
            throw ValidationError("the target is a //Tools/Bundler target name, such as app-debug")
        }
        for pin in pin where !Self.isPin(pin) {
            throw ValidationError("--pin \(pin) is not `section.key=value`")
        }
    }

    /// Whether `pin` is a `buck2 -c` setting with a value: a pin left empty
    /// would let the host's own value stand.
    static func isPin(_ pin: String) -> Bool {
        guard let equals = pin.firstIndex(of: "=") else { return false }
        let key = pin[..<equals].split(separator: ".", omittingEmptySubsequences: false)
        return key.count == 2 && key.allSatisfy { !$0.isEmpty } && pin.index(after: equals) != pin.endIndex
    }

    func run() throws {
        let root = FileManager.default.currentDirectoryPath
        guard FileManager.default.fileExists(atPath: root + "/.buckroot") else {
            throw ValidationError("run from the repository root (buck2 run does)")
        }
        let environment = hostEnvironment()
        let requested = directory.isEmpty ? root : directory
        guard Self.isHostPath(requested) else {
            throw ValidationError(
                """
                the checkout's path on the host, \(requested), must be absolute and use only letters, digits \
                and / . _ - + @ , (the host's shell reads it): set `[remote_build] directory` to such a path
                """)
        }

        step("checking \(host)'s buck2")
        try checkBuck2(environment: environment)

        step("copying the checkout to \(host):\(requested)")
        // `rsync --delete` mirrors this checkout over the directory, so it
        // must be empty or this tool's copy: a mistyped `directory` must not
        // erase whatever is there. The guard reports where it looked, and
        // every later step uses that path, so none can land elsewhere.
        let prepared = try env([
            "ssh", "-o", "BatchMode=yes", host,
            """
            mkdir -p \(quote(requested)) && cd \(quote(requested)) && if [ -e \(Self.marker) ]; then :; \
            elif [ -z "$(ls -A)" ]; then touch \(Self.marker); else exit \(Self.notOurs); fi && pwd -P
            """,
        ]).outcome()
        switch prepared.status {
        case 0: break
        case Self.notOurs:
            throw Failure(
                """
                \(host):\(requested) is not empty and has no \(Self.marker), so it is not a copy this tool made; \
                refusing to mirror into it. Set `[remote_build] directory` to an empty or new directory.
                """)
        default: throw Failure("could not prepare \(host):\(requested): ssh exited \(prepared.status)")
        }
        // The directory with its links resolved, which is also the root
        // buck2 reports its outputs under.
        let remoteRoot = prepared.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isHostPath(remoteRoot) else {
            throw Failure(
                "\(host):\(requested) resolves to \(remoteRoot), which the host's shell would not read as one path")
        }
        let quotedRoot = quote(remoteRoot)
        try env(
            ["rsync", "-a", "--delete"]
                // The host's own .buckconfig.local is its settings, not this Mac's.
                + ["/buck-out", "/.build", "/build", "/.buckd", "/.git", "node_modules", "/.buckconfig.local"]
                .flatMap { ["--exclude", $0] }
                + ["--exclude", "/\(Self.marker)"]
                + ["\(root)/", "\(host):\(remoteRoot)/"]
        ).run()

        // `buck2 -c` for each of this Mac's pins, after `test` or `run`.
        let pins = pin.map { "-c " + quote($0) }.joined(separator: " ")

        step("checking \(host)'s toolchain")
        try env([
            "ssh", "-o", "BatchMode=yes", host,
            "cd \(quotedRoot) && \(environment) && buck2 test \(pins) " + Self.toolchainTests.joined(separator: " "),
        ]).run()

        let label = "//Tools/Bundler:\(target)"
        step("building \(label) on \(host)")
        let command = try decodeCommand(
            env(
                [
                    "ssh", "-o", "BatchMode=yes", host,
                    """
                    cd \(quotedRoot) && \(environment) && f=$(mktemp) && trap 'rm -f "$f"' EXIT && \
                    buck2 run \(pins) \(quote(label)) --command-args-file "$f" >&2 && cat "$f"
                    """,
                ]
            ).output())

        let parts = URL(fileURLWithPath: output ?? root + "/build/remote")
            .appendingPathComponent(target)
        step("copying the built parts to \(parts.path)")
        let argv = try fetchParts(of: command, remoteRoot: remoteRoot, into: parts)

        step("running the bundler here")
        try Subprocess(argv[0], Array(argv.dropFirst()) + bundlerArguments).run()
    }

    // MARK: - The host

    /// The shell assignment that puts `path` first on the host's PATH.
    private func hostEnvironment() -> String {
        let directories = path.split(separator: ":").map { directory in
            directory.hasPrefix("~/") ? "\"$HOME\"/" + quote(String(directory.dropFirst(2))) : quote(String(directory))
        }
        return "export PATH=\((directories + ["\"$PATH\""]).joined(separator: ":"))"
    }

    /// Fails unless the host's buck2 is this Mac's: another one could build
    /// something else without failing, as its prelude is bundled.
    private func checkBuck2(environment: String) throws {
        let buck2 = try env(["buck2", "--version"]).output().trimmingCharacters(in: .whitespacesAndNewlines)
        let there = try env(["ssh", "-o", "BatchMode=yes", host, "\(environment)\nbuck2 --version 2>&1"]).output()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard there == buck2 else {
            throw Failure(
                "\(host) cannot build what this Mac would (PATH there starts with `[remote_build] path`):\n  "
                    + "buck2 is \(there), here it is \(buck2)")
        }
    }

    // MARK: - The bundler command

    /// What `buck2 run --command-args-file` writes: the command it would
    /// have run.
    private struct BundlerCommand: Decodable {
        var argv: [String]
    }

    private func decodeCommand(_ json: String) throws -> BundlerCommand {
        let command = try JSONDecoder().decode(BundlerCommand.self, from: Data(json.utf8))
        guard !command.argv.isEmpty else { throw Failure("buck2 reported an empty command") }
        return command
    }

    /// Copies every Buck output the command names from the host into
    /// `parts`, one folder per option (`bundler` for the executable), and
    /// returns the command with those paths, and with this Mac's Xcode for
    /// the host's. Each folder is replaced in place, so an unchanged part is
    /// not sent again.
    private func fetchParts(of command: BundlerCommand, remoteRoot: String, into parts: URL) throws -> [String] {
        let buckOut = remoteRoot + "/buck-out/"
        var argv = command.argv
        for (index, argument) in argv.enumerated() where argument.hasPrefix(buckOut) {
            let option = index == 0 ? "bundler" : argv[index - 1]
            guard index == 0 || option.hasPrefix("--") else {
                throw Failure("\(argument) is not the value of an option in the bundler command")
            }
            guard Self.isHostPath(argument) else {
                throw Failure("\(argument) is not a path the host's shell would read as one, for rsync")
            }
            let folder = parts.appendingPathComponent(index == 0 ? option : String(option.dropFirst(2)))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Links out of a part (into the rest of buck-out) are copied as
            // what they point at: buck-out here holds this Mac's builds.
            try env(["rsync", "-a", "--delete", "--copy-unsafe-links", "\(host):\(argument)", folder.path + "/"]).run()
            argv[index] = folder.appendingPathComponent((argument as NSString).lastPathComponent).path
        }
        guard let option = argv.firstIndex(of: "--developer-dir"), option + 1 < argv.count else {
            throw Failure("the bundler command has no --developer-dir")
        }
        argv[option + 1] = developerDir
        return argv
    }

    /// Whether a shell on the host reads `path` as one absolute path, unchanged:
    /// rsync's remote side reads its path through one, unquoted, so a `~`, a
    /// space or a glob there would name another directory than the guard
    /// checked.
    static func isHostPath(_ path: String) -> Bool {
        path.hasPrefix("/")
            && path.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII
                    && (CharacterSet.alphanumerics.contains(scalar) || "/._-+@,".unicodeScalars.contains(scalar))
            }
    }

    // MARK: - Processes

    /// `value` as one word for the host's shell.
    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func step(_ message: String) {
        FileHandle.standardError.write(Data("==> \(message)\n".utf8))
    }

    /// `arguments`, the first found on PATH.
    private func env(_ arguments: [String]) -> Subprocess {
        Subprocess("/usr/bin/env", arguments)
    }
}
