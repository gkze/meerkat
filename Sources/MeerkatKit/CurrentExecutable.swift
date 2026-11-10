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

    /// The bundle `executable` would be in, were it one of `executables`.
    public static func containing(executable: URL) -> URL {
        executables.split(separator: "/").reduce(executable.deletingLastPathComponent()) { directory, _ in
            directory.deletingLastPathComponent()
        }
    }

    /// `directory` in the resources of the bundle `executable` would be in.
    public static func resource(_ directory: String, besideExecutable executable: URL) -> URL {
        containing(executable: executable).appendingPathComponent(resources).appendingPathComponent(directory)
    }
}
