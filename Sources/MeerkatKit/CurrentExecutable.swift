import Foundation

extension URL {
    /// The running executable, as named: the main bundle's, or the path it
    /// was started by when it has no bundle (a test runner, a binary in
    /// buck-out). Not resolved, so a caller that needs the bundle it lives
    /// in resolves symlinks itself.
    public static var currentExecutable: URL {
        Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    }
}

/// Where things are in Meerkat.app, relative to the bundle: the one layout
/// the bundler builds and everything that finds a part of it reads (the
/// agent's plist, the toolchain locators, the bundle's own lookup).
/// `DaemonService` names what is in it.
public enum AppBundle {
    /// Every executable: the app, the daemon, the CLI.
    public static let executables = "Contents/MacOS"
    /// The toolchains the daemon and the CLI run, and the notices.
    public static let resources = "Contents/Resources"
    /// Where `SMAppService` looks for an agent's plist.
    public static let launchAgents = "Contents/Library/LaunchAgents"
    /// Where the daemon's own app bundle lives.
    public static let loginItems = "Contents/Library/LoginItems"
    /// The daemon's bundle, relative to Meerkat.app. macOS posts a
    /// notification only for a bundle's main executable, so the daemon is one
    /// rather than a helper in `executables` (docs/design/meerkatd.md). Its
    /// file name is what the privacy lists in System Settings show, so it is
    /// Meerkat too.
    public static let daemonBundle = loginItems + "/Meerkat.app"

    /// The bundle `executable` would be in, were it one of `executables`.
    ///
    /// The daemon runs from its own bundle inside Meerkat.app
    /// (`daemonBundle`), and what it reads — the toolchains, the notices — is
    /// the app's, so a bundle under `loginItems` resolves to the app above it.
    public static func containing(executable: URL) -> URL {
        let bundle = above(executable.deletingLastPathComponent(), executables)
        let parent = bundle.deletingLastPathComponent()
        let nested = loginItems.split(separator: "/").map(String.init)
        guard parent.pathComponents.count > nested.count, Array(parent.pathComponents.suffix(nested.count)) == nested
        else { return bundle }
        return above(parent, loginItems)
    }

    /// The directory `relative` (a path inside a bundle) is relative to.
    private static func above(_ directory: URL, _ relative: String) -> URL {
        relative.split(separator: "/").reduce(directory) { directory, _ in directory.deletingLastPathComponent() }
    }

    /// `directory` in the resources of the bundle `executable` would be in.
    public static func resource(_ directory: String, besideExecutable executable: URL) -> URL {
        containing(executable: executable).appendingPathComponent(resources).appendingPathComponent(directory)
    }
}
