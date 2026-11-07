/// A release version under Semantic Versioning 2.0.0 (https://semver.org):
/// what `[meerkat] version` in .buckconfig declares and what release tags
/// (`v<version>`) name.
///
/// Build metadata (`+…`) is rejected rather than ignored. The bundle's build
/// number (CFBundleVersion) comes from the history, so a release version has
/// no use for it, and without it two versions are equal exactly when they
/// have the same precedence, which keeps `Comparable` consistent with `==`.
public struct SemanticVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// One dot-separated pre-release identifier.
    public enum Identifier: Hashable, Sendable, CustomStringConvertible {
        case numeric(UInt64)
        case alphanumeric(String)

        public var description: String {
            switch self {
            case .numeric(let value): String(value)
            case .alphanumeric(let text): text
            }
        }
    }

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let text: String
        public let reason: String

        public var description: String { "\"\(text)\" is not a release version (SemVer 2.0.0): \(reason)" }
    }

    public let major: UInt64
    public let minor: UInt64
    public let patch: UInt64
    /// Empty for a normal release.
    public let prerelease: [Identifier]

    public init(_ text: String) throws(ParseError) {
        func fail(_ reason: String) -> ParseError { ParseError(text: text, reason: reason) }
        if text.contains("+") { throw fail("build metadata (+…) is not accepted") }
        let core: Substring
        let prerelease: Substring?
        if let dash = text.firstIndex(of: "-") {
            core = text[..<dash]
            prerelease = text[text.index(after: dash)...]
        } else {
            core = text[...]
            prerelease = nil
        }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3 else { throw fail("expected major.minor.patch") }
        var parsed: [UInt64] = []
        for number in numbers {
            guard let value = Self.numeric(number) else {
                throw fail("\"\(number)\" is not a number without leading zeros")
            }
            parsed.append(value)
        }
        var identifiers: [Identifier] = []
        if let prerelease {
            for identifier in prerelease.split(separator: ".", omittingEmptySubsequences: false) {
                guard !identifier.isEmpty,
                    identifier.utf8.allSatisfy({ Self.isIdentifierByte($0) })
                else {
                    throw fail("pre-release identifiers are non-empty [0-9A-Za-z-]")
                }
                if identifier.utf8.allSatisfy({ (0x30...0x39).contains($0) }) {
                    guard let value = Self.numeric(identifier) else {
                        throw fail("numeric pre-release identifier \"\(identifier)\" has a leading zero or overflows")
                    }
                    identifiers.append(.numeric(value))
                } else {
                    identifiers.append(.alphanumeric(String(identifier)))
                }
            }
        }
        (major, minor, patch) = (parsed[0], parsed[1], parsed[2])
        self.prerelease = identifiers
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    /// CFBundleShortVersionString, which macOS reads as at most three
    /// period-separated integers, so the pre-release part is left out.
    public var bundleShortVersion: String { "\(major).\(minor).\(patch)" }

    /// The release's tag.
    public var tag: String { "v\(self)" }

    public var description: String {
        let core = bundleShortVersion
        return prerelease.isEmpty ? core : core + "-" + prerelease.map(\.description).joined(separator: ".")
    }

    /// Precedence (SemVer 2.0.0 §11).
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        // A pre-release precedes its normal release.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, _): return false
        case (false, true): return true
        case (false, false): break
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (left, right) {
            case (.numeric(let left), .numeric(let right)): return left < right
            case (.numeric, .alphanumeric): return true
            case (.alphanumeric, .numeric): return false
            case (.alphanumeric(let left), .alphanumeric(let right)):
                // ASCII order, which these identifiers are limited to.
                return Array(left.utf8).lexicographicallyPrecedes(right.utf8)
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func numeric(_ text: Substring) -> UInt64? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
            text == "0" || text.first != "0"
        else { return nil }
        return UInt64(text)
    }

    private static func isIdentifierByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D: true
        default: false
        }
    }
}
