import Foundation
import MeerkatIPC
import ServiceManagement

/// Installs and removes `meerkatd` as a LaunchAgent through `SMAppService`.
///
/// This is the only install mechanism: the CLI (`meerkat agent install`)
/// and the app's install button both call it (`installAndAwait`), and both
/// run from inside Meerkat.app, so either one sees and changes the same
/// registration, and both wait for a daemon the same way. The
/// agent's plist lives in the bundle at
/// `Contents/Library/LaunchAgents/com.gkze.meerkat.daemon.plist`.
public enum AgentRegistration {
    public enum Status: String, Sendable, Codable {
        /// Registered and allowed to run.
        case enabled
        /// Registered, but switched off in System Settings > General > Login
        /// Items & Extensions.
        case requiresApproval
        case notRegistered
        /// The running executable is not inside Meerkat.app, so there is no
        /// agent plist to register.
        case notInBundle
    }

    public enum RegistrationError: Error, CustomStringConvertible {
        case notInBundle(String)
        case failed(String)

        public var description: String {
            switch self {
            case .notInBundle(let path):
                return """
                    \(path) is not inside Meerkat.app, so it cannot manage the agent. \
                    Build the app with `buck2 run //Tools/Bundler:app -- --install` and run \
                    ~/Applications/Meerkat.app/Contents/MacOS/meerkat agent install.
                    """
            case .failed(let message): return message
            }
        }
    }

    /// The `.app` containing the running executable, resolving symlinks (a
    /// `meerkat` on PATH is usually a symlink into the bundle).
    public static var appBundle: URL? {
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath()
        var directory = executable.deletingLastPathComponent()
        while directory.path != "/" {
            if directory.pathExtension == "app" {
                let plist = directory.appendingPathComponent("Contents/Library/LaunchAgents/\(DaemonService.plistName)")
                return FileManager.default.fileExists(atPath: plist.path) ? directory : nil
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    public static var status: Status {
        guard appBundle != nil else { return .notInBundle }
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    /// Registers the agent, replacing an existing registration.
    ///
    /// launchd keeps the plist it read at registration: restarting the
    /// daemon after an upgrade runs the new binary under the old plist
    /// (observed: a changed `ProcessType` stayed in effect until the agent
    /// was registered again). So an existing registration is removed and
    /// made again, which also restarts the daemon from this bundle.
    ///
    /// A registration made from another copy of Meerkat.app (an earlier
    /// install location, or a build folder since deleted) reads as
    /// `notRegistered` here, but launchd still holds its job. `register()`
    /// then reuses that job instead of submitting a new one, so the old
    /// process keeps running, and once its bundle is gone every respawn
    /// fails with EX_CONFIG (observed 2026-10-26). Such a job is removed
    /// first, so `register()` always submits one that runs this bundle.
    @discardableResult
    public static func install() throws -> Status {
        guard appBundle != nil else { throw RegistrationError.notInBundle(executablePath) }
        do {
            if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            } else {
                try removeForeignJob()
            }
            try service.register()
        } catch let error as RegistrationError {
            throw error
        } catch {
            throw RegistrationError.failed("registering the agent failed: \(error.localizedDescription)")
        }
        return status
    }

    /// What registering found, once the daemon had its chance to start.
    public enum Started: Sendable, Equatable {
        /// Registered, and a daemon other than the one before answered.
        case answering(DaemonIdentity)
        /// Registered and allowed to run, but no new daemon answered within
        /// `startLimit`: launchd can accept a registration and still refuse
        /// to run the binary (a launch constraint from an earlier signature
        /// of the app, recorded again only once the app has launched).
        case silent
        /// Registered, but switched off in Login Items until the user allows
        /// it, so launchd runs nothing yet.
        case requiresApproval
    }

    /// How long a new daemon may take to answer: launchd may hold a respawn
    /// for its 10 s throttle interval.
    public static let startLimit: Duration = .seconds(30)

    /// `install()`, then waits for a daemon other than the one that answered
    /// before to answer. Success is that daemon, not the registration. The
    /// one route for every caller that registers (the CLI, the app's Install
    /// and Turn On, its Reinstall), so they agree on what counts. `register`
    /// stands in for `install()` in tests.
    public static func installAndAwait(
        client: any DaemonConnection, within limit: Duration = startLimit,
        register: @escaping @Sendable () throws -> Status = { try install() }
    ) async throws -> Started {
        // Read before registering: after it, the old daemon may still answer
        // and would count as new.
        let before = try? await client.daemonIdentity(within: DaemonClient.pingLimit)
        // SMAppService and launchctl block; kept off the caller's actor.
        let status = try await Task.detached { try register() }.value
        switch status {
        case .enabled:
            return try await newDaemon(replacing: before, client: client, within: limit).map(Started.answering)
                ?? .silent
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notInBundle:
            throw RegistrationError.failed("the agent did not register (status \(status.rawValue))")
        }
    }

    /// `restart()`, then the daemon launchd started in place of the one
    /// before, or nil when none answered within `startLimit`.
    public static func restartAndAwait(client: any DaemonConnection) async throws -> DaemonIdentity? {
        let before = try? await client.daemonIdentity(within: DaemonClient.pingLimit)
        try await Task.detached { try AgentRegistration.restart() }.value
        return try await newDaemon(replacing: before, client: client)
    }

    /// The daemon once one other than `before` answers, within `limit`; nil
    /// if none does. Each ping is bounded, so a daemon that accepts and never
    /// replies (when a restart is most needed) does not hold the wait past
    /// its limit. Throws `CancellationError` once the caller is cancelled,
    /// rather than ping without pause until the limit.
    public static func newDaemon(
        replacing before: DaemonIdentity?, client: any DaemonConnection, within limit: Duration = startLimit
    ) async throws -> DaemonIdentity? {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if let daemon = try? await client.daemonIdentity(within: DaemonClient.pingLimit), daemon != before {
                return daemon
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    /// Removes the agent, including a job registered from another copy of
    /// Meerkat.app (see `install()`), which `SMAppService` here cannot see.
    public static func uninstall() throws {
        guard appBundle != nil else { throw RegistrationError.notInBundle(executablePath) }
        guard service.status != .notRegistered else { return try removeForeignJob() }
        do {
            try service.unregister()
        } catch {
            throw RegistrationError.failed("unregistering the agent failed: \(error.localizedDescription)")
        }
    }

    /// Restarts the running daemon through launchd, keeping the registration
    /// and the plist launchd already holds (unlike `install()`).
    ///
    /// launchd owns the process, so this works even when meerkatd no longer
    /// answers XPC, which is when a restart is most needed. `SMAppService` has
    /// no restart, so this is `launchctl kickstart -k` on the agent's job.
    /// Blocks until launchctl exits; launchd may delay the respawn by up to
    /// its throttle interval (10 s by default).
    public static func restart() throws {
        guard appBundle != nil else { throw RegistrationError.notInBundle(executablePath) }
        guard service.status == .enabled else {
            throw RegistrationError.failed("meerkatd is not enabled as a login item, so launchd is not running it")
        }
        let result = try launchctl(["kickstart", "-k", job])
        guard result.status == 0 else {
            throw RegistrationError.failed(
                "launchctl kickstart exited \(result.status)\(result.output.isEmpty ? "" : ": \(result.output)")")
        }
    }

    /// Boots out the agent's launchd job when one exists although this
    /// bundle has no registration, meaning another copy of Meerkat.app
    /// registered it.
    private static func removeForeignJob() throws {
        guard try launchctl(["print", job]).status == 0 else { return }
        let removed = try launchctl(["bootout", job])
        guard removed.status == 0 else {
            throw RegistrationError.failed(
                "removing the job registered from another copy of Meerkat.app failed: launchctl bootout exited "
                    + "\(removed.status)\(removed.output.isEmpty ? "" : ": \(removed.output)")")
        }
    }

    /// The agent's job in the user's GUI domain, as launchctl names it.
    private static var job: String { "gui/\(getuid())/\(DaemonService.label)" }

    /// Runs launchctl and returns its exit status and combined output.
    private static func launchctl(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw RegistrationError.failed("running launchctl failed: \(error.localizedDescription)")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, message)
    }

    /// Opens Login Items settings, where a disabled agent is switched on.
    public static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static var service: SMAppService {
        .agent(plistName: DaemonService.plistName)
    }

    private static var executablePath: String {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().path
    }
}
