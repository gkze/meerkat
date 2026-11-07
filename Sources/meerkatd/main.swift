import Foundation
import MeerkatDaemon

// meerkatd: the LaunchAgent. launchd starts it from Meerkat.app (see
// Contents/Library/LaunchAgents/com.gkze.meerkat.daemon.plist) and
// keeps it alive; clients reach it over XPC.

// A write to a pipe whose reader is gone (an exec effect's child, an http
// connection) must fail, not kill the daemon.
signal(SIGPIPE, SIG_IGN)

let daemon: Daemon
do {
    daemon = try Daemon(runtime: DenoRuntime.handlerRuntime)
} catch {
    FileHandle.standardError.write(Data("meerkatd: cannot start: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}

// SIGTERM is how launchd stops an agent; shut sources and the runtime down
// before exiting.
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    Task {
        await daemon.stop()
        exit(EXIT_SUCCESS)
    }
}
termination.resume()

Task {
    do {
        try await daemon.start()
    } catch {
        FileHandle.standardError.write(Data("meerkatd: \(error)\n".utf8))
        exit(EXIT_FAILURE)
    }
}

// NSWorkspace, distributed-notification and CoreGraphics callbacks are
// delivered through the main run loop; `dispatchMain()` would service the
// main queue but never deliver them.
CFRunLoopRun()
