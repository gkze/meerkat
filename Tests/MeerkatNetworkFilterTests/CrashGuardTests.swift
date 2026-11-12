import Foundation
import MeerkatNetworkFilter
import Testing

/// The crash-loop guard's decisions.
struct CrashGuardTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    @Test func cleanRunsNeverCount() {
        var guardRecord = CrashGuard()
        for minute in 0..<20 {
            #expect(guardRecord.starting(at: at(Double(minute) * 60)) == .start)
            guardRecord.stopped()
        }
        #expect(guardRecord.crashes.isEmpty)
    }

    @Test func aStartAfterAnUncleanRunCountsACrash() {
        var guardRecord = CrashGuard()
        _ = guardRecord.starting(at: at(0))
        #expect(guardRecord.starting(at: at(5)) == .start)
        #expect(guardRecord.crashes == [at(5)])
    }

    /// The third crash within ten minutes refuses, until the oldest leaves
    /// the window.
    @Test func repeatedCrashesRefuseUntilTheWindowPasses() {
        var guardRecord = CrashGuard()
        _ = guardRecord.starting(at: at(0))
        #expect(guardRecord.starting(at: at(10)) == .start)
        #expect(guardRecord.starting(at: at(20)) == .start)
        #expect(guardRecord.starting(at: at(30)) == .refuse(until: at(10 + CrashGuard.window)))
        // A refused start leaves no run, so retries don't count more crashes.
        #expect(guardRecord.starting(at: at(40)) == .refuse(until: at(10 + CrashGuard.window)))
        #expect(guardRecord.crashes.count == 3)
        // Ten minutes after the oldest, a start is allowed again.
        #expect(guardRecord.starting(at: at(10 + CrashGuard.window)) == .start)
    }

    @Test func crashesSpreadBeyondTheWindowNeverRefuse() {
        var guardRecord = CrashGuard()
        _ = guardRecord.starting(at: at(0))
        for crash in 1...10 {
            #expect(guardRecord.starting(at: at(Double(crash) * (CrashGuard.window / 2 + 1))) == .start)
        }
        #expect(guardRecord.crashes.count <= 2)
    }

    /// A clock set back is no reason to keep refusing.
    @Test func crashesFromTheFutureAreDropped() {
        var guardRecord = CrashGuard()
        _ = guardRecord.starting(at: at(1_000))
        _ = guardRecord.starting(at: at(1_010))
        _ = guardRecord.starting(at: at(1_020))
        #expect(guardRecord.starting(at: at(0)) == .start)
    }

    @Test func survivesItsOwnEncoding() throws {
        var guardRecord = CrashGuard()
        _ = guardRecord.starting(at: at(0))
        _ = guardRecord.starting(at: at(5))
        let decoded = try JSONDecoder().decode(CrashGuard.self, from: JSONEncoder().encode(guardRecord))
        #expect(decoded == guardRecord)
    }
}
