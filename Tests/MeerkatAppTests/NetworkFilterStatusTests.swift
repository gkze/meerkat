import Foundation
import Testing

@testable import MeerkatApp

/// What Settings › Network shows, from the facts the app has.
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
