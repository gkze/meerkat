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
