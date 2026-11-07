/// Whether a push publishes a release. The repository declares one version
/// (`[meerkat] version` in .buckconfig); a version with no `v<version>` tag
/// yet is published, and one already tagged is a successful no-op, so
/// changing the version is what releases.
public enum ReleasePlan: Equatable, Sendable {
    case publish(SemanticVersion)
    case alreadyReleased(SemanticVersion)

    public struct NotNewer: Error, Equatable, CustomStringConvertible {
        public let version: SemanticVersion
        public let latest: SemanticVersion

        public var description: String {
            "version \(version) is not tagged and precedes the latest release, \(latest); declare a later version"
        }
    }

    /// Decides from the repository's tags. Tags that are not `v` followed by
    /// a release version are not releases and are ignored. A version below
    /// the latest release fails rather than publishing out of order.
    public init(version: SemanticVersion, tags: some Sequence<String>) throws(NotNewer) {
        let released = tags.compactMap { tag -> SemanticVersion? in
            guard tag.hasPrefix("v") else { return nil }
            return try? SemanticVersion(String(tag.dropFirst()))
        }
        if released.contains(version) {
            self = .alreadyReleased(version)
        } else if let latest = released.max(), version < latest {
            throw NotNewer(version: version, latest: latest)
        } else {
            self = .publish(version)
        }
    }
}
