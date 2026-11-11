import Foundation
import MeerkatKit
import Testing

@testable import MeerkatIPC

/// Every executable Meerkat ships finds the same Meerkat.app, whose resources
/// (the compiler, the lint tools, the notices) and protected paths it uses.
struct BundleLayoutTests {
    let app = URL(fileURLWithPath: "/Applications/Meerkat.app")

    @Test func eachExecutableResolvesToTheApp() {
        for program in [DaemonService.daemonProgram, DaemonService.cliPath, AppBundle.executables + "/MeerkatApp"] {
            let executable = app.appendingPathComponent(program)
            #expect(AppBundle.containing(executable: executable).path == app.path, "\(program)")
        }
    }

    /// The daemon is the main executable of its own bundle, which macOS
    /// requires of a process that posts notifications.
    @Test func theDaemonIsItsOwnBundlesMainExecutable() {
        let daemon = app.appendingPathComponent(DaemonService.daemonProgram)
        let bundle = daemon.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #expect(bundle.path == app.appendingPathComponent(AppBundle.daemonBundle).path)
        #expect(bundle.pathExtension == "app")
    }

    /// A bundle that only looks nested, or a binary outside any bundle,
    /// resolves no further than its own layout says.
    @Test func otherLayoutsAreNotWidened() {
        let lone = URL(fileURLWithPath: "/Applications/Other.app/Contents/MacOS/other")
        #expect(AppBundle.containing(executable: lone).path == "/Applications/Other.app")
        let shallow = URL(fileURLWithPath: "/Library/LoginItems/Helper.app/Contents/MacOS/helper")
        #expect(AppBundle.containing(executable: shallow).path == "/Library/LoginItems/Helper.app")
    }
}
