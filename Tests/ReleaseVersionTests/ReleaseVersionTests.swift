import ReleaseVersion
import Testing

/// SemVer 2.0.0 parsing and precedence, and the release decision built on
/// them.
struct ReleaseVersionTests {
    @Test(arguments: ["0.2.0", "0.2.0-alpha.1", "1.0.0-0.3.7", "1.0.0-x-y-z.--", "10.20.30"])
    func validVersionsRoundTrip(_ text: String) throws {
        #expect(try SemanticVersion(text).description == text)
    }

    @Test(arguments: [
        "", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.03", "v1.2.3", "1.2.3-", "1.2.3-alpha..1",
        "1.2.3-01", "1.2.3-alpha_1", "1.2.3+build", "1.2.3-alpha+build", "-1.2.3", "1.2.18446744073709551616",
    ])
    func invalidVersionsAreRejected(_ text: String) {
        #expect(throws: SemanticVersion.ParseError.self) { try SemanticVersion(text) }
    }

    /// The precedence example in SemVer 2.0.0 §11, in ascending order.
    @Test func precedenceFollowsTheSpecification() throws {
        let ordered = try [
            "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11",
            "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "2.0.0",
        ].map(SemanticVersion.init)
        for (lower, higher) in zip(ordered, ordered.dropFirst()) {
            #expect(lower < higher, "\(lower) < \(higher)")
            #expect(!(higher < lower), "!(\(higher) < \(lower))")
        }
        #expect(ordered.shuffled().sorted() == ordered)
    }

    @Test func bundleVersionDropsThePrerelease() throws {
        let version = try SemanticVersion("0.2.0-alpha.1")
        #expect(version.bundleShortVersion == "0.2.0")
        #expect(version.isPrerelease)
        #expect(version.tag == "v0.2.0-alpha.1")
        #expect(try !SemanticVersion("0.2.0").isPrerelease)
    }

    @Test func untaggedVersionIsPublished() throws {
        let version = try SemanticVersion("0.2.0-alpha.2")
        #expect(try ReleasePlan(version: version, tags: ["v0.2.0-alpha.1", "spike", "v0.1.0"]) == .publish)
        #expect(try ReleasePlan(version: version, tags: []) == .publish)
    }

    @Test func taggedVersionIsANoOp() throws {
        let version = try SemanticVersion("0.2.0-alpha.1")
        #expect(try ReleasePlan(version: version, tags: ["v0.2.0-alpha.1", "v0.2.0-alpha.2"]) == .alreadyReleased)
    }

    @Test func versionBelowTheLatestReleaseFails() throws {
        let version = try SemanticVersion("0.2.0-alpha.1")
        #expect(throws: ReleasePlan.NotNewer.self) {
            try ReleasePlan(version: version, tags: ["v0.2.0"])
        }
    }

    /// Tags that are not releases neither publish nor block one.
    @Test func nonReleaseTagsAreIgnored() throws {
        let version = try SemanticVersion("0.1.0")
        #expect(try ReleasePlan(version: version, tags: ["9.9.9", "v9.9", "vnext", "v9.9.9+x"]) == .publish)
    }
}
