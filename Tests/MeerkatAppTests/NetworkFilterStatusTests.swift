import Foundation
import MeerkatIPC
import MeerkatKit
import Testing

@testable import MeerkatApp

/// What Settings › General › Network shows, from the facts the app has.
struct NetworkFilterStatusTests {
    @Test func aBuildWithoutTheProfilesHasNoFilter() {
        #expect(
            NetworkFilterStatus.of(bundled: false, appPath: "/Applications/Meerkat.app", filterEnabled: true)
                == .notInThisBuild)
    }

    @Test func outsideApplicationsItSaysWhereToMoveIt() {
        let path = "/Users/me/Applications/Meerkat.app"
        let status = NetworkFilterStatus.of(bundled: true, appPath: path, filterEnabled: nil)
        #expect(status == .needsApplications(current: path))
        #expect(status.explanation.contains(path))
    }

    @Test(arguments: [(Bool?.none, NetworkFilterStatus.off), (false, .off), (true, .on)])
    func inApplicationsItFollowsTheSavedFilter(enabled: Bool?, expected: NetworkFilterStatus) {
        #expect(
            NetworkFilterStatus.of(bundled: true, appPath: "/Applications/Meerkat.app", filterEnabled: enabled)
                == expected)
    }

    @Test func aLookalikePathIsNotApplications() {
        #expect(
            NetworkFilterStatus.of(bundled: true, appPath: "/ApplicationsExtra/Meerkat.app", filterEnabled: true)
                == .needsApplications(current: "/ApplicationsExtra/Meerkat.app"))
    }
}

/// Turn On and Turn Off wait on their own system-extension request; the
/// launch-time upgrade, which shares the delegate, cannot end the wait.
struct ExtensionRequestWaitTests {
    struct Failed: Error {}

    @Test func anotherRequestsResultLeavesTheWait() async throws {
        let awaited = NSObject()
        let upgrade = NSObject()
        var wait = ExtensionRequestWait()
        try await withCheckedThrowingContinuation { continuation in
            wait.begin(ObjectIdentifier(awaited), continuation)
            // The upgrade fails and succeeds first: neither is Turn Off's.
            let upgradeFailed = wait.finish(ObjectIdentifier(upgrade), .failure(Failed()))
            let upgraded = wait.finish(ObjectIdentifier(upgrade), .success(()))
            let ended = wait.finish(ObjectIdentifier(awaited), .success(()))
            #expect(!upgradeFailed && !upgraded && ended)
        }
        // Once ended, a late result resumes nothing.
        let late = wait.finish(ObjectIdentifier(awaited), .success(()))
        #expect(!late)
        withExtendedLifetime((awaited, upgrade)) {}
    }
}

/// A filter that is on and silent gets one session restart, then the user is
/// told; anything that answers, or is off, ends the watch.
struct ListenerRepairTests {
    let start = ContinuousClock.now
    let silent = NetworkFilterHealth(NetworkFilterUnavailable.notAnswering)

    func at(_ seconds: Int) -> ContinuousClock.Instant { start + .seconds(seconds) }

    @Test func aSilentFilterIsRestartedOnceAfterTheGraceThenReported() {
        var repair = ListenerRepair()
        #expect(repair.next(filterOn: true, health: silent, at: at(0)) == .wait)
        #expect(repair.next(filterOn: true, health: silent, at: at(89)) == .wait)
        #expect(repair.next(filterOn: true, health: silent, at: at(90)) == .restart)
        // The restart gets a grace of its own.
        #expect(repair.next(filterOn: true, health: silent, at: at(179)) == .wait)
        #expect(repair.next(filterOn: true, health: silent, at: at(180)) == .giveUp)
        #expect(repair.gaveUp)
    }

    /// A healthy swap: silent while the extension retries its listener.
    @Test func anAnswerWithinTheGraceEndsTheWatch() {
        var repair = ListenerRepair()
        #expect(repair.next(filterOn: true, health: silent, at: at(0)) == .wait)
        #expect(repair.next(filterOn: true, health: .answering, at: at(45)) == .done)
        #expect(!repair.restarted)
    }

    /// Another build's extension answers: the upgrade replaces it, and its
    /// replacement gets the full grace.
    @Test func aRefusalIsNotSilenceAndRestartsTheGrace() {
        var repair = ListenerRepair()
        let refused = NetworkFilterHealth(cause: .refused, problem: "another build")
        #expect(repair.next(filterOn: true, health: silent, at: at(0)) == .wait)
        #expect(repair.next(filterOn: true, health: refused, at: at(60)) == .wait)
        #expect(repair.next(filterOn: true, health: silent, at: at(70)) == .wait)
        #expect(repair.next(filterOn: true, health: silent, at: at(159)) == .wait)
        #expect(repair.next(filterOn: true, health: silent, at: at(160)) == .restart)
    }

    /// meerkatd not answering says nothing about the filter.
    @Test func noWordFromMeerkatdKeepsWaitingWithoutCounting() {
        var repair = ListenerRepair()
        #expect(repair.next(filterOn: true, health: nil, at: at(0)) == .wait)
        #expect(repair.next(filterOn: true, health: silent, at: at(200)) == .wait)
    }

    @Test func aFilterThatIsOffOrUnreachableEndsTheWatch() {
        var repair = ListenerRepair()
        #expect(repair.next(filterOn: false, health: silent, at: at(0)) == .done)
        let unsigned = NetworkFilterHealth(cause: .unreachable, problem: "meerkatd is not signed by a team")
        #expect(repair.next(filterOn: true, health: unsigned, at: at(0)) == .done)
    }

    /// After Turn Off and On the filter is judged afresh, without a second
    /// automatic restart.
    @Test func aUserChangeClearsTheReportButNotTheRestart() {
        var repair = ListenerRepair()
        _ = repair.next(filterOn: true, health: silent, at: at(0))
        _ = repair.next(filterOn: true, health: silent, at: at(90))
        _ = repair.next(filterOn: true, health: silent, at: at(180))
        repair.userChanged()
        #expect(!repair.gaveUp)
        #expect(repair.next(filterOn: true, health: silent, at: at(200)) == .wait)
        #expect(repair.next(filterOn: true, health: silent, at: at(290)) == .giveUp)
    }
}
