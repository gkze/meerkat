import ArgumentParser
import Foundation
import MeerkatIPC
import MeerkatKit
import MeerkatNetworkFilter
import MeerkatRules
import ReleaseVersion
import ToolProcess

// Assembles and signs Meerkat.app from parts Buck has built.
//
//   buck2 run //Tools/Bundler:app                  # -> build/Meerkat.app
//   buck2 run //Tools/Bundler:app -- --install     # also install to
//                                                  # /Applications and
//                                                  # register the agent
//   buck2 run //Tools/Bundler:preview              # the app alone, as its
//                                                  # own app -> build/Meerkat
//                                                  # Preview.app
//   buck2 run //Tools/Bundler:app -- --notarize --archive build/Meerkat.zip
//                                                  # a release: Developer ID,
//                                                  # notarized and stapled
//
// Buck builds the executables and the toolchains they run, in the mode the
// target names (buck2/rules/bundle.bzl), and passes their paths; this tool
// copies them into the bundle layout the daemon expects, compiles the icon,
// writes the plists, and signs nested code inside-out with the keychain's
// identity, which is why it is not a build action. The layout is
// AppBundle's, and the names the app, daemon and agent find each other by
// are DaemonService's.

/// The two bundles this tool builds. They share the app executable, icon and
/// Info.plist contents, and differ in identity and in what else they hold.
enum Variant {
    /// Meerkat.app: the app, the CLI, the daemon, its LaunchAgent and the
    /// toolchains they run.
    case full
    /// The app alone under its own bundle identifier, so it runs beside the
    /// installed Meerkat.app without sharing its defaults or privacy
    /// grants. With no LaunchAgent plist inside, AgentRegistration sees no
    /// agent to manage, so a preview can never register or replace the
    /// installed agent; it is a client of the installed daemon.
    case preview

    var identifier: String {
        switch self {
        case .full: DaemonService.bundleIdentifier
        case .preview: "\(DaemonService.bundleIdentifier).preview"
        }
    }

    var name: String {
        switch self {
        case .full: "Meerkat"
        case .preview: "Meerkat Preview"
        }
    }
}

@main
struct Bundle: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bundle",
        abstract: "Build, assemble and sign Meerkat.app."
    )

    @Option(help: "The app executable (MeerkatApp).")
    var app: String

    @OptionGroup var parts: FullBundleParts

    @OptionGroup var networkFilterProfiles: NetworkFilterProfiles

    @Option(help: "A resource bundle of a module the app links, copied into Contents/Resources. Repeatable.")
    var resourceBundle: [String] = []

    @Option(
        help:
            "Code signing identity (default: $MEERKAT_SIGNING_IDENTITY, else the only Apple Development or Developer ID Application identity in the keychain; - signs ad hoc, for checking the bundle: its daemon accepts no client)."
    )
    var identity: String?

    @Option(
        help: "The release version ([meerkat] version in .buckconfig; bundle_command passes it).",
        transform: SemanticVersion.init)
    var appVersion: SemanticVersion

    @Option(help: "The macOS it runs on ([meerkat] minimum_macos in .buckconfig; bundle_command passes it).")
    var minimumSystemVersion: String

    @Option(
        help:
            "The Xcode whose actool and notarytool run ([swift] developer_dir in .buckconfig; bundle_command passes it)."
    )
    var developerDir: String

    @Option(help: "Where to write the bundle, absolute or from the repository root (default: build/<name>.app).")
    var output: String?

    @Flag(
        help: """
            Sign for distribution and notarize: a Developer ID Application identity, a secure timestamp, \
            submission to Apple's notary service, and the ticket stapled to the bundle. The notary API key is \
            read from $MEERKAT_NOTARY_KEY (the .p8 file), $MEERKAT_NOTARY_KEY_ID and $MEERKAT_NOTARY_ISSUER.
            """)
    var notarize = false

    @Option(help: "Also write the finished bundle, zipped as Finder would (ditto), to this path.")
    var archive: String?

    @Flag(help: "Copy the bundle to \(DaemonService.installedApp) and install the agent from there.")
    var install = false

    @Flag(
        help:
            "Build only the app, as Meerkat Preview.app with its own bundle identifier, to run beside the installed app. It holds no daemon, CLI or agent, so it uses the installed daemon and cannot change the agent."
    )
    var preview = false

    func validate() throws {
        if preview && install {
            throw ValidationError("--preview cannot be combined with --install")
        }
        if !preview { _ = try parts.resolved() }
        if preview && (networkFilterProfiles.appProfile != nil || networkFilterProfiles.networkFilterProfile != nil) {
            throw ValidationError("the preview carries no network filter")
        }
        if notarize {
            if preview { throw ValidationError("--notarize is for Meerkat.app, not the preview") }
            _ = try NotaryKey.fromEnvironment()
        }
    }

    private var variant: Variant { preview ? .preview : .full }

    func run() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".buckroot").path) else {
            throw ValidationError("run from the repository root (buck2 run does)")
        }
        // xcrun, and so every Xcode tool run below, takes the Xcode from
        // DEVELOPER_DIR before xcode-select's: the one Buck built with.
        setenv("DEVELOPER_DIR", developerDir, 1)
        let identity = try resolveIdentity()
        if notarize && !identity.hasPrefix("Developer ID Application:") {
            throw ValidationError("--notarize needs a Developer ID Application identity, not \"\(identity)\"")
        }

        // Checked before anything is built: a profile macOS would refuse
        // fails here, not at launch.
        let filterProfiles = variant == .full ? try networkFilterProfiles.resolved() : nil
        let output = self.output ?? "build/\(variant.name).app"
        step("assembling \(output)")
        let app = URL(fileURLWithPath: output, relativeTo: root).standardizedFileURL
        let staging = app.deletingLastPathComponent().appendingPathComponent(".\(app.lastPathComponent).staging")
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: staging)
        let contents = staging.appendingPathComponent("Contents")
        let macOS = staging.appendingPathComponent(AppBundle.executables)
        let resources = staging.appendingPathComponent(AppBundle.resources)
        for directory in [macOS, resources] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try fileManager.copyItem(
            at: URL(fileURLWithPath: self.app), to: macOS.appendingPathComponent(DaemonService.appExecutable))
        for bundle in resourceBundle.map(URL.init(fileURLWithPath:)) {
            try fileManager.copyItem(at: bundle, to: resources.appendingPathComponent(bundle.lastPathComponent))
        }
        if variant == .full { try assembleDaemonAndCLI(parts.resolved(), into: staging) }

        step("compiling the app icon (actool)")
        let iconKeys = try compileIcon(root: root, into: resources)

        let build = try buildNumber(root: root)
        if variant == .full { try assembleNotifier(iconKeys: iconKeys, build: build, staging: staging) }
        if let filterProfiles {
            try assembleNetworkFilter(
                executable: parts.resolved().networkFilter, profile: filterProfiles.filter, build: build,
                staging: staging)
            try FileManager.default.copyItem(
                at: filterProfiles.app.path, to: contents.appendingPathComponent("embedded.provisionprofile"))
        }
        try write(
            plist: infoPlist(build: build).merging(iconKeys) { $1 },
            to: contents.appendingPathComponent("Info.plist"))
        try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))

        step("signing with \"\(identity)\"")
        // Inside-out: nested executables first, the bundle (and its main
        // executable) last. Identifiers are what peer requirements and the
        // privacy database see.
        if variant == .full {
            try signResourceExecutables(in: resources, identity: identity)
            try signDaemonAndCLI(in: staging, identity: identity, scratch: staging)
        }
        if let filterProfiles {
            try signNetworkFilter(in: staging, profile: filterProfiles.filter, identity: identity)
        }
        // The app asks for the Automation permission meerkatd's Apple Events
        // effects need (macOS prompts only a foreground app), and the
        // hardened runtime blocks Apple Events without this entitlement.
        let appEntitlements = staging.deletingLastPathComponent().appendingPathComponent(".app.entitlements")
        // With the network filter, the app also installs the system extension
        // and configures the content filter, as its profile grants.
        let appleEvents: [String: Any] = ["com.apple.security.automation.apple-events": true]
        try write(
            plist: filterProfiles.map {
                $0.app.signingEntitlements(
                    appleEvents.merging(["com.apple.developer.system-extension.install": true]) { $1 })
            } ?? appleEvents,
            to: appEntitlements)
        defer { try? fileManager.removeItem(at: appEntitlements) }
        try sign(staging, identity: identity, identifier: variant.identifier, entitlements: appEntitlements)
        try Subprocess("/usr/bin/codesign", ["--verify", "--strict", "--deep", staging.path]).run()

        if fileManager.fileExists(atPath: app.path) {
            _ = try fileManager.replaceItemAt(app, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: app)
        }
        print("built \(app.path)")

        if notarize { try notarizeAndStaple(app) }
        if let archive {
            let destination = URL(fileURLWithPath: archive, relativeTo: root).standardizedFileURL
            try? fileManager.removeItem(at: destination)
            try zip(app, to: destination)
            print("archived \(destination.path)")
        }
        if install { try installBundle(app) }
    }

    /// Everything in Meerkat.app beside the app: the CLI and the daemon,
    /// the toolchains they run, the third-party notices, and the LaunchAgent
    /// plist.
    private func assembleDaemonAndCLI(_ parts: FullBundleParts.Resolved, into bundle: URL) throws {
        let fileManager = FileManager.default
        let typescript = URL(fileURLWithPath: parts.typescript)
        let lint = URL(fileURLWithPath: parts.lintToolchain)
        let macOS = bundle.appendingPathComponent(AppBundle.executables)
        let resources = bundle.appendingPathComponent(AppBundle.resources)
        let agentPlist = bundle.appendingPathComponent(DaemonService.agentPlist)
        // tsrs resolves its lib.*.d.ts next to its own executable, and
        // codesign treats every file under Helpers as nested code, so the
        // package lives in Resources, and the binary is signed there
        // (`signResourceExecutables`).
        let typescriptDirectory = resources.appendingPathComponent(TypeScriptToolchain.bundledDirectory)
        for directory in [agentPlist.deletingLastPathComponent(), typescriptDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try fileManager.copyItem(
            at: URL(fileURLWithPath: parts.cli), to: macOS.appendingPathComponent(DaemonService.cliExecutable))
        // The daemon is the main executable of its own bundle: the notification
        // center posts only for a bundle's main executable, and a helper here
        // is refused even permission to ask (AppBundle.daemonBundle).
        let notifier = bundle.appendingPathComponent(AppBundle.daemonBundle)
        for directory in [AppBundle.executables, AppBundle.resources] {
            try fileManager.createDirectory(
                at: notifier.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try fileManager.copyItem(
            at: URL(fileURLWithPath: parts.daemon), to: bundle.appendingPathComponent(DaemonService.daemonProgram))
        for item in try fileManager.contentsOfDirectory(atPath: typescript.path) {
            try fileManager.copyItem(
                at: typescript.appendingPathComponent(item), to: typescriptDirectory.appendingPathComponent(item))
        }
        // The runtime's declarations, for `meerkat rules check`, which does
        // not link the runtime (meerkatd takes them from it).
        try fileManager.copyItem(
            at: URL(fileURLWithPath: parts.runtimeTypes),
            to: typescriptDirectory.appendingPathComponent(TypeScriptToolchain.runtimeDeclarationsFile))
        // Like tsrs, the lint tools are resources, signed in place:
        // meerkatd and meerkat run them as child processes.
        try fileManager.copyItem(at: lint, to: resources.appendingPathComponent(LintToolchain.bundledDirectory))
        let notices = resources.appendingPathComponent("THIRD_PARTY_NOTICES")
        // Buck's output is a symbolic link, and `copyItem` copies a link as one.
        try fileManager.copyItem(at: URL(fileURLWithPath: parts.notices).resolvingSymlinksInPath(), to: notices)
        // AppKit's standard About panel shows Credits.html from Resources.
        try Data("Third-party notices: \(AppBundle.resources)/\(notices.lastPathComponent)".utf8)
            .write(to: notices.deletingLastPathComponent().appendingPathComponent("Credits.html"))
        try write(plist: self.agentPlist, to: agentPlist)
    }

    /// The daemon's bundle: the app's name, version and compiled icon, so a
    /// banner and System Settings show the Meerkat logo under the identity the
    /// daemon posts with.
    private func assembleNotifier(iconKeys: [String: Any], build: String, staging: URL) throws {
        let fileManager = FileManager.default
        let notifier = staging.appendingPathComponent(AppBundle.daemonBundle)
        let resources = notifier.appendingPathComponent(AppBundle.resources)
        let appResources = staging.appendingPathComponent(AppBundle.resources)
        for name in try fileManager.contentsOfDirectory(atPath: appResources.path)
        where name == "Assets.car" || name.hasSuffix(".icns") {
            try fileManager.copyItem(
                at: appResources.appendingPathComponent(name), to: resources.appendingPathComponent(name))
        }
        var plist: [String: Any] = [
            "CFBundleIdentifier": DaemonService.daemonBundleIdentifier,
            "CFBundleExecutable": DaemonService.daemonExecutable,
            "CFBundleName": "Meerkat",
            "CFBundleDisplayName": "Meerkat",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": appVersion.bundleShortVersion,
            "CFBundleVersion": build,
            "CFBundleInfoDictionaryVersion": "6.0",
            "LSMinimumSystemVersion": minimumSystemVersion,
            // No Dock icon and no window: it exists to host the daemon under an
            // identity macOS lets post notifications.
            "LSUIElement": true,
        ]
        plist.merge(iconKeys) { $1 }
        // The daemon raises the permission prompts, and its Bundle.main is
        // this bundle, which is where macOS and Permissions.swift look.
        plist.merge(Self.usageDescriptions.mapValues { $0 as Any }) { $1 }
        try write(plist: plist, to: notifier.appendingPathComponent("Contents/Info.plist"))
        try Data("APPL????".utf8).write(to: notifier.appendingPathComponent("Contents/PkgInfo"))
    }

    /// Signs every executable the bundle carries as a resource (tsrs and
    /// the lint tools) with the bundle's identity. Their own signatures are
    /// ad hoc, with no team, hardened runtime or timestamp, and the notary
    /// service checks every Mach-O file in a submission, resources included.
    private func signResourceExecutables(in resources: URL, identity: String) throws {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: resources, includingPropertiesForKeys: keys) else {
            return
        }
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true, try Self.isMachO(url) else { continue }
            try sign(url, identity: identity, identifier: "\(DaemonService.bundleIdentifier).\(url.lastPathComponent)")
        }
    }

    /// Whether the file starts with a Mach-O or universal-binary magic number.
    private static func isMachO(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let magic = try handle.read(upToCount: 4), magic.count == 4 else { return false }
        let value = magic.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return [0xFEED_FACF, 0xCFFA_EDFE, 0xFEED_FACE, 0xCEFA_EDFE, 0xCAFE_BABE, 0xBEBA_FECA, 0xCAFE_BABF, 0xBFBA_FECA]
            .contains(value)
    }

    /// Signs the daemon and the CLI, which the bundle's signature then seals.
    private func signDaemonAndCLI(in bundle: URL, identity: String, scratch staging: URL) throws {
        // V8, embedded in meerkatd, compiles JavaScript to machine code;
        // under the hardened runtime that takes MAP_JIT, which this allows.
        // The hardened runtime also blocks sending Apple Events without the
        // automation entitlement; the `appearance.setDark` effect sends them
        // to System Events (docs/design/effects.md). Only the app also gets
        // the automation entitlement; nothing else gets either.
        let entitlements = staging.deletingLastPathComponent().appendingPathComponent(".daemon.entitlements")
        try write(
            plist: ["com.apple.security.cs.allow-jit": true, "com.apple.security.automation.apple-events": true],
            to: entitlements)
        defer { try? FileManager.default.removeItem(at: entitlements) }
        // Inside-out: the daemon binary, then its bundle (which seals its
        // Info.plist and icon), then the CLI. The app's signature seals all.
        let notifier = bundle.appendingPathComponent(AppBundle.daemonBundle)
        try sign(
            bundle.appendingPathComponent(DaemonService.daemonProgram), identity: identity,
            identifier: DaemonService.daemonBundleIdentifier, entitlements: entitlements)
        try sign(
            notifier, identity: identity, identifier: DaemonService.daemonBundleIdentifier,
            entitlements: entitlements)
        try sign(
            bundle.appendingPathComponent(AppBundle.executables)
                .appendingPathComponent(DaemonService.cliExecutable), identity: identity,
            identifier: "\(DaemonService.bundleIdentifier).cli")
    }

    // MARK: - Inputs

    private func resolveIdentity() throws -> String {
        if let identity { return identity }
        if let environment = ProcessInfo.processInfo.environment["MEERKAT_SIGNING_IDENTITY"], !environment.isEmpty {
            return environment
        }
        let listing = try Subprocess("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]).output()
        let names = listing.split(separator: "\n").compactMap { line -> String? in
            guard let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""), open < close else {
                return nil
            }
            let name = String(line[line.index(after: open)..<close])
            return name.hasPrefix("Apple Development:") || name.hasPrefix("Developer ID Application:") ? name : nil
        }
        guard names.count == 1, let name = names.first else {
            throw ValidationError(
                """
                found \(names.count) signing identities; pass --identity or set MEERKAT_SIGNING_IDENTITY. \
                Ad-hoc signing does not work: the daemon only accepts clients signed by the same team.
                """)
        }
        return name
    }

    /// Compiles Tools/Bundler/AppIcon.icon, an Icon Composer document, into
    /// `resources`: Assets.car, which macOS renders with Liquid Glass, and
    /// AppIcon.icns for whatever reads only icns. Returns the Info.plist keys
    /// that name the icon, as actool reports them.
    ///
    /// actool exits 0 even when it compiles nothing (a missing or malformed
    /// document), so success is judged by its outputs, and its report is
    /// shown only when they are missing.
    private func compileIcon(root: URL, into resources: URL) throws -> [String: Any] {
        let document = root.appendingPathComponent("Tools/Bundler/AppIcon.icon")
        guard FileManager.default.fileExists(atPath: document.appendingPathComponent("icon.json").path) else {
            throw ValidationError("no icon document at \(document.path)")
        }
        let partial = FileManager.default.temporaryDirectory.appendingPathComponent(
            "meerkat-icon-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: partial) }
        let report = try Subprocess(
            "/usr/bin/xcrun",
            [
                "actool", document.path, "--compile", resources.path,
                "--platform", "macosx", "--target-device", "mac",
                "--minimum-deployment-target", minimumSystemVersion,
                "--app-icon", "AppIcon", "--include-all-app-icons",
                "--output-partial-info-plist", partial.path,
                "--output-format", "human-readable-text", "--errors", "--warnings",
            ], in: root
        ).output()
        let keys =
            (try? Data(contentsOf: partial)).flatMap {
                try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
            } ?? [:]
        guard keys["CFBundleIconName"] is String,
            FileManager.default.fileExists(atPath: resources.appendingPathComponent("Assets.car").path)
        else {
            throw ValidationError("actool did not compile \(document.path):\n\(report)")
        }
        return keys
    }

    /// CFBundleVersion: the number of commits, which only grows along main.
    /// Outside a checkout a local build gets 1. A notarized build is a
    /// release, whose number must be right, so it needs the full history: a
    /// shallow clone would count only the commits it fetched.
    private func buildNumber(root: URL) throws -> String {
        guard notarize else {
            return
                (try? Subprocess("/usr/bin/git", ["rev-list", "--count", "HEAD"], in: root).output()
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "1"
        }
        let shallow = try Subprocess("/usr/bin/git", ["rev-parse", "--is-shallow-repository"], in: root).output()
        guard shallow.trimmingCharacters(in: .whitespacesAndNewlines) == "false" else {
            throw ValidationError("--notarize needs the full history for the build number; this clone is shallow")
        }
        return try Subprocess("/usr/bin/git", ["rev-list", "--count", "HEAD"], in: root).output()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Plists

    private func infoPlist(build: String) -> [String: Any] {
        [
            "CFBundleIdentifier": variant.identifier,
            "CFBundleExecutable": DaemonService.appExecutable,
            "CFBundleName": variant.name,
            "CFBundleDisplayName": variant.name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": appVersion.bundleShortVersion,
            "CFBundleVersion": build,
            "CFBundleInfoDictionaryVersion": "6.0",
            "LSMinimumSystemVersion": minimumSystemVersion,
            "LSApplicationCategoryType": "public.app-category.developer-tools",
            "NSPrincipalClass": "NSApplication",
            "NSHighResolutionCapable": true,
        ].merging(Self.usageDescriptions.mapValues { $0 as Any }) { $1 }
    }

    /// Shown in the permission prompts raised when a rule first subscribes to
    /// an event that needs them (Permissions.swift), or, for Automation, by
    /// Settings asking on the daemon's behalf. Both the app and the daemon's
    /// bundle carry them: each process reads its own Bundle.main. Without the
    /// Bluetooth key macOS kills a process that uses it.
    private static let usageDescriptions: [String: String] = [
        "NSLocationUsageDescription": locationUsage,
        "NSLocationWhenInUseUsageDescription": locationUsage,
        "NSBluetoothAlwaysUsageDescription":
            "A Meerkat rule reacts to Bluetooth devices connecting and disconnecting (bluetooth.devices).",
        "NSAppleEventsUsageDescription":
            "A Meerkat rule switches between light and dark mode through System Events (appearance.setDark).",
    ]

    private static let locationUsage =
        "A Meerkat rule reads the name of the Wi-Fi network this Mac is on (network.wifi), which macOS treats as location data."

    /// The LaunchAgent. `BundleProgram` is relative to the bundle, so the
    /// registration follows the app wherever it is installed.
    ///
    /// `Standard`, not `Background` or `Adaptive`: rules must react promptly
    /// whether or not a client is connected. Under the background band the
    /// bundled compiler ran 12x slower (0.5 s instead of 0.04 s), and on a loaded
    /// machine a rule edit took 12 s to load. Idle, the daemon does no work,
    /// so its priority costs nothing.
    private var agentPlist: [String: Any] {
        [
            "Label": DaemonService.label,
            "BundleProgram": DaemonService.daemonProgram,
            "MachServices": [DaemonService.machService: true],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Standard",
            "AssociatedBundleIdentifiers": [DaemonService.bundleIdentifier],
            "ThrottleInterval": 10,
        ]
    }

    func write(plist: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)
    }

    // MARK: - Signing and install

    /// The notary service requires a secure timestamp, which costs a request
    /// to Apple's timestamp server per signature, so only a notarized build
    /// asks for one.
    func sign(_ url: URL, identity: String, identifier: String, entitlements: URL? = nil) throws {
        var arguments = [
            "--force", "--sign", identity, "--options", "runtime", "--identifier", identifier,
            notarize ? "--timestamp" : "--timestamp=none",
        ]
        if let entitlements { arguments += ["--entitlements", entitlements.path] }
        try Subprocess("/usr/bin/codesign", arguments + [url.path]).run()
    }

    /// Submits the signed bundle to Apple's notary service and waits for its
    /// verdict, then staples the ticket so Gatekeeper accepts the app
    /// offline, and asks Gatekeeper to assess the result.
    private func notarizeAndStaple(_ app: URL) throws {
        let key = try NotaryKey.fromEnvironment()
        let submission = FileManager.default.temporaryDirectory.appendingPathComponent(
            "meerkat-notary-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: submission) }
        try zip(app, to: submission)

        step("notarizing (notarytool; usually a few minutes)")
        let (status, output) = try Subprocess(
            "/usr/bin/xcrun",
            ["notarytool", "submit", submission.path, "--wait", "--output-format", "json"] + key.arguments
        ).outcome()
        struct Result: Decodable {
            let id: String
            let status: String
        }
        guard let result = try? JSONDecoder().decode(Result.self, from: Data(output.utf8)) else {
            throw ValidationError("notarytool submit failed (\(status)):\n\(output)")
        }
        guard result.status == "Accepted" else {
            // The log names each file the service rejected and why.
            let (_, log) = try Subprocess("/usr/bin/xcrun", ["notarytool", "log", result.id] + key.arguments).outcome()
            throw ValidationError("notarization \(result.id) ended \(result.status):\n\(log)")
        }

        step("stapling the ticket")
        try Subprocess("/usr/bin/xcrun", ["stapler", "staple", app.path]).run()
        try Subprocess("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose", app.path]).run()
    }

    /// A zip of the bundle as Finder makes one (ditto keeps the extended
    /// attributes and resource forks codesign may rely on); the notary
    /// service and the release both take this form.
    private func zip(_ app: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Subprocess("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, destination.path]).run()
    }

    /// Each attempt waits up to 30 s for the daemon (`agent install`).
    private static let registrationAttempts = 3

    private func installBundle(_ app: URL) throws {
        let destination = URL(fileURLWithPath: DaemonService.installedApp)
        let applications = destination.deletingLastPathComponent()
        step("installing \(destination.path)")
        let copy = applications.appendingPathComponent(".\(destination.lastPathComponent).installing")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: app, to: copy)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: copy)
        } else {
            try FileManager.default.moveItem(at: copy, to: destination)
        }
        // macOS gives the agent the launch constraint of the app's signature
        // as it last recorded it, and records it again a few seconds after
        // the app launches, not when the bundle is replaced. A registration
        // made before that holds this build to the previous build's
        // signature, which launchd then refuses to run (observed 2026-11-05
        // across a change of signing team and from ad hoc to a team). The
        // constraint is fixed when registering, so waiting does not help:
        // the app opens first, in the background, and a registration whose
        // daemon never answers is made again. Only that outcome: any other
        // failure would fail the same way again.
        try Subprocess("/usr/bin/open", ["-g", destination.path]).run()
        let cli = destination.appendingPathComponent(DaemonService.cliPath).path
        for attempt in 1...Self.registrationAttempts {
            do {
                try Subprocess(cli, ["agent", "install"]).run()
                break
            } catch let failure as SubprocessFailure
                where failure.status == DaemonService.registeredButSilentExit && attempt < Self.registrationAttempts
            {
                step("registering the agent again (attempt \(attempt + 1) of \(Self.registrationAttempts))")
            }
        }
        print(
            """
            installed. Put the CLI on your PATH with:
              ln -sf \(destination.path)/\(DaemonService.cliPath) ~/.local/bin/\(DaemonService.cliExecutable)
            """)
    }

    // MARK: - Progress

    private func step(_ message: String) {
        FileHandle.standardError.write(Data("==> \(message)\n".utf8))
    }
}

/// The parts of Meerkat.app beside the app, which bundle_command passes
/// (buck2/rules/bundle.bzl): the full bundle needs each, and the preview
/// holds none.
struct FullBundleParts: ParsableArguments {
    @Option(help: "The CLI (meerkat). Required unless --preview.")
    var cli: String?

    @Option(help: "The daemon (meerkatd). Required unless --preview.")
    var daemon: String?

    @Option(help: "The TypeScript compiler's directory (tsrs and its lib.*.d.ts). Required unless --preview.")
    var typescript: String?

    @Option(help: "The runtime's declarations (Sources/meerkat-rules/deno.d.ts). Required unless --preview.")
    var runtimeTypes: String?

    @Option(help: "The lint toolchain directory, in LintToolchain's layout. Required unless --preview.")
    var lintToolchain: String?

    @Option(help: "The third-party notices (//Tools/Notices:notices). Required unless --preview.")
    var notices: String?

    @Option(
        help:
            "The network filter's system extension executable. Required unless --preview; bundled only with the profiles."
    )
    var networkFilter: String?

    struct Resolved {
        let cli: String
        let daemon: String
        let typescript: String
        let runtimeTypes: String
        let lintToolchain: String
        let notices: String
        let networkFilter: String
    }

    /// Every part, or the options missing.
    func resolved() throws -> Resolved {
        let parts = [
            ("--cli", cli), ("--daemon", daemon), ("--typescript", typescript), ("--runtime-types", runtimeTypes),
            ("--lint-toolchain", lintToolchain), ("--notices", notices), ("--network-filter", networkFilter),
        ]
        guard let cli, let daemon, let typescript, let runtimeTypes, let lintToolchain, let notices, let networkFilter
        else {
            let missing = parts.filter { $0.1 == nil }.map(\.0)
            throw ValidationError("the full bundle needs \(missing.joined(separator: ", "))")
        }
        return Resolved(
            cli: cli, daemon: daemon, typescript: typescript, runtimeTypes: runtimeTypes,
            lintToolchain: lintToolchain, notices: notices, networkFilter: networkFilter)
    }
}

/// The App Store Connect API key notarytool authenticates with, from the
/// environment, so CI can supply it from secrets and nothing names it on a
/// command line that logs show.
struct NotaryKey {
    let path: String
    let id: String
    let issuer: String

    static func fromEnvironment() throws -> Self {
        let environment = ProcessInfo.processInfo.environment
        let names = ["MEERKAT_NOTARY_KEY", "MEERKAT_NOTARY_KEY_ID", "MEERKAT_NOTARY_ISSUER"]
        let values = names.map { environment[$0].flatMap { $0.isEmpty ? nil : $0 } }
        let missing = zip(names, values).filter { $0.1 == nil }.map(\.0)
        guard missing.isEmpty, let path = values[0], let id = values[1], let issuer = values[2] else {
            throw ValidationError("--notarize needs \(missing.map { "$\($0)" }.joined(separator: ", "))")
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw ValidationError("$MEERKAT_NOTARY_KEY names no readable file")
        }
        return Self(path: path, id: id, issuer: issuer)
    }

    var arguments: [String] { ["--key", path, "--key-id", id, "--issuer", issuer] }
}
