import Foundation

/// Where the daemon keeps things. Read when the daemon starts, so a change
/// applies after `meerkat agent restart`; the CLI reads the same values to
/// find the rules directory without asking the daemon.
///
/// Each path is, in order: an environment variable, which is how tests and
/// development runs stay out of the user's real directories (the installed
/// agent's plist sets none); a key in the `com.gkze.meerkat` defaults domain,
/// which is how a user moves one (`defaults write com.gkze.meerkat
/// RulesDirectory ~/rules`); or the built-in default.
public struct DaemonPaths: Sendable {
    public var rulesDirectory: URL
    public var cacheDirectory: URL
    public var ruleDatabase: URL
    public var sampleDatabase: URL

    public init(rulesDirectory: URL, cacheDirectory: URL, ruleDatabase: URL, sampleDatabase: URL) {
        self.rulesDirectory = rulesDirectory
        self.cacheDirectory = cacheDirectory
        self.ruleDatabase = ruleDatabase
        self.sampleDatabase = sampleDatabase
    }

    /// One path's environment variable and defaults key.
    public enum Setting: String, CaseIterable, Sendable {
        case rulesDirectory = "RulesDirectory"
        case cacheDirectory = "CacheDirectory"
        case ruleDatabase = "RuleDatabase"
        case sampleDatabase = "SampleDatabase"

        public var environmentVariable: String {
            switch self {
            case .rulesDirectory: "MEERKAT_RULES_DIR"
            case .cacheDirectory: "MEERKAT_CACHE_DIR"
            case .ruleDatabase: "MEERKAT_RULE_DB"
            case .sampleDatabase: "MEERKAT_DB"
            }
        }
    }

    /// The defaults domain's file, which rule code may not write: a rule
    /// that could move the rules directory could load rules it wrote.
    public static var preferencesFile: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences/\(DaemonService.bundleIdentifier).plist")
    }

    /// A string value in the `com.gkze.meerkat` defaults domain. Read
    /// through CFPreferences by domain name, so it is the same domain from
    /// meerkatd, the CLI and the app, whatever each one's main bundle is;
    /// and from that domain alone, not `CFPreferencesCopyAppValue`'s search
    /// list, because a rule granted the global domain must not be able to
    /// set these.
    public static func preference(_ key: String) -> String? {
        CFPreferencesCopyValue(
            key as CFString, DaemonService.bundleIdentifier as CFString, kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost) as? String
    }

    /// Whether `domain` names this domain, as CFPreferences would read it:
    /// a file's path works as a domain, and APFS ignores case. A rule that
    /// could write it could move the rules directory.
    ///
    /// The name is compared, not the file: a path domain that is a symbolic
    /// or hard link to this domain's file under another name passes. That
    /// is safe because cfprefsd doesn't write through either. The write
    /// reports success, stays in cfprefsd's memory under the link's path,
    /// and reaches neither the file nor a read of this domain (checked on
    /// macOS 27.0.1).
    public static func isOwnDomain(_ domain: String) -> Bool {
        let name = URL(fileURLWithPath: domain).lastPathComponent
        let bare = name.lowercased().hasSuffix(".plist") ? String(name.dropLast(6)) : name
        return bare.caseInsensitiveCompare(DaemonService.bundleIdentifier) == .orderedSame
    }

    public static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        preferences: (String) -> String? = DaemonPaths.preference
    ) -> DaemonPaths {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let support = home.appendingPathComponent("Library/Application Support/\(DaemonService.bundleIdentifier)")
        func path(_ setting: Setting, _ fallback: URL) -> URL {
            let value = environment[setting.environmentVariable] ?? preferences(setting.rawValue)
            return value.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? fallback
        }
        return DaemonPaths(
            rulesDirectory: path(.rulesDirectory, home.appendingPathComponent(".config/meerkat/rules")),
            cacheDirectory: path(
                .cacheDirectory, home.appendingPathComponent("Library/Caches/\(DaemonService.bundleIdentifier)")),
            ruleDatabase: path(.ruleDatabase, support.appendingPathComponent("rules.db")),
            sampleDatabase: path(.sampleDatabase, support.appendingPathComponent("samples.db"))
        )
    }
}
