import ArgumentParser
import Foundation
import MeerkatIPC
import MeerkatKit
import MeerkatNetworkFilter
import ReleaseVersion
import ToolProcess

// The network filter's system extension in Meerkat.app
// (docs/design/network-filter.md). It and the entitlements the app needs
// for it are restricted: macOS runs them only with a provisioning profile
// that grants them. So the bundle carries the extension only when both
// profiles are given, and a bundle without them is the app without the
// filter, which anyone can build and run.

/// The two Developer ID provisioning profiles, given together or not at all.
struct NetworkFilterProfiles: ParsableArguments {
    @Option(
        help:
            "The Developer ID provisioning profile for com.gkze.meerkat (System Extension and Network Extensions capabilities). With --network-filter-profile, the bundle carries the network filter."
    )
    var appProfile: String?

    @Option(
        help:
            "The Developer ID provisioning profile for \(FilterService.extensionIdentifier) (Network Extensions capability)."
    )
    var networkFilterProfile: String?

    /// Both profiles decoded and checked, or nil when neither was given.
    func resolved() throws -> (app: ProvisioningProfile, filter: ProvisioningProfile)? {
        switch (appProfile, networkFilterProfile) {
        case (nil, nil): return nil
        case (let app?, let filter?):
            let app = try ProvisioningProfile(path: app)
            let filter = try ProvisioningProfile(path: filter)
            try app.check(identifier: DaemonService.bundleIdentifier, needs: .app)
            try filter.check(identifier: FilterService.extensionIdentifier, needs: .filter)
            guard app.team == filter.team else {
                throw ValidationError("the two profiles are for teams \(app.team) and \(filter.team)")
            }
            return (app, filter)
        default:
            throw ValidationError("--app-profile and --network-filter-profile go together")
        }
    }
}

/// A provisioning profile as `security cms` decodes it.
struct ProvisioningProfile {
    let path: URL
    let team: String
    let entitlements: [String: Any]
    let expires: Date

    /// The content filter a Developer ID system extension provides.
    static let contentFilter = "content-filter-provider-systemextension"

    enum Needs {
        case app, filter
    }

    init(path: String) throws {
        self.path = URL(fileURLWithPath: path)
        let decoded = try Subprocess("/usr/bin/security", ["cms", "-D", "-i", path]).output()
        guard
            let plist = try PropertyListSerialization.propertyList(from: Data(decoded.utf8), format: nil)
                as? [String: Any],
            let team = (plist["TeamIdentifier"] as? [String])?.first,
            let entitlements = plist["Entitlements"] as? [String: Any],
            let expires = plist["ExpirationDate"] as? Date
        else {
            throw ValidationError("\(path) is not a provisioning profile")
        }
        self.team = team
        self.entitlements = entitlements
        self.expires = expires
    }

    /// Refuses a profile that would make macOS refuse the bundle: another
    /// identifier, an expired profile, or one without what the part needs.
    func check(identifier: String, needs: Needs) throws {
        let name = path.lastPathComponent
        guard entitlements["com.apple.application-identifier"] as? String == "\(team).\(identifier)" else {
            throw ValidationError("\(name) is not for \(identifier)")
        }
        guard expires > Date() else { throw ValidationError("\(name) expired on \(expires)") }
        let networkExtension = entitlements["com.apple.developer.networking.networkextension"] as? [String] ?? []
        guard networkExtension.contains(Self.contentFilter) else {
            throw ValidationError("\(name) does not grant the \(Self.contentFilter) Network Extension")
        }
        if needs == .app, entitlements["com.apple.developer.system-extension.install"] as? Bool != true {
            throw ValidationError("\(name) does not grant the System Extension capability")
        }
    }

    /// The entitlements a signature claims under this profile: the
    /// identifiers it binds them to, and `extra`.
    func signingEntitlements(_ extra: [String: Any]) -> [String: Any] {
        var claimed: [String: Any] = [
            "com.apple.application-identifier": entitlements["com.apple.application-identifier"] as Any,
            "com.apple.developer.team-identifier": team,
            "com.apple.developer.networking.networkextension": [Self.contentFilter],
        ]
        claimed.merge(extra) { $1 }
        return claimed
    }
}

extension AppBundle {
    /// Where macOS looks for an app's system extensions.
    static let systemExtensions = "Contents/Library/SystemExtensions"
    /// The network filter's bundle, named by its identifier as macOS requires.
    static let networkFilterBundle = systemExtensions + "/\(FilterService.extensionIdentifier).systemextension"
}

extension Bundle {
    /// The system extension: its executable, Info.plist (naming the provider
    /// class and the Mach service, under the team's app group) and profile.
    func assembleNetworkFilter(
        executable: String, profile: ProvisioningProfile, build: String, staging: URL
    ) throws {
        let fileManager = FileManager.default
        let extensionBundle = staging.appendingPathComponent(AppBundle.networkFilterBundle)
        let macOS = extensionBundle.appendingPathComponent(AppBundle.executables)
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.copyItem(
            at: URL(fileURLWithPath: executable), to: macOS.appendingPathComponent(FilterService.extensionIdentifier))
        try fileManager.copyItem(
            at: profile.path, to: extensionBundle.appendingPathComponent("Contents/embedded.provisionprofile"))
        let plist: [String: Any] = [
            "CFBundleIdentifier": FilterService.extensionIdentifier,
            "CFBundleExecutable": FilterService.extensionIdentifier,
            "CFBundleName": "Meerkat Network Filter",
            "CFBundleDisplayName": "Meerkat Network Filter",
            "CFBundlePackageType": "SYSX",
            "CFBundleShortVersionString": appVersion.bundleShortVersion,
            "CFBundleVersion": build,
            "CFBundleInfoDictionaryVersion": "6.0",
            "LSMinimumSystemVersion": minimumSystemVersion,
            "NSSystemExtensionUsageDescription":
                "Meerkat counts which processes use the network, and how much, for your rules. It allows all traffic and reads none of it.",
            "NetworkExtension": [
                "NEMachServiceName": FilterService.machServiceName(team: profile.team),
                "NEProviderClasses": ["com.apple.networkextension.filter-data": "MeerkatFilterDataProvider"],
            ],
        ]
        try write(plist: plist, to: extensionBundle.appendingPathComponent("Contents/Info.plist"))
    }

    /// Signs the extension, sandboxed, with exactly the content filter and
    /// its app group, before the app's signature seals it.
    func signNetworkFilter(in staging: URL, profile: ProvisioningProfile, identity: String) throws {
        let extensionBundle = staging.appendingPathComponent(AppBundle.networkFilterBundle)
        let entitlements = staging.deletingLastPathComponent().appendingPathComponent(".network-filter.entitlements")
        try write(
            plist: profile.signingEntitlements([
                "com.apple.security.app-sandbox": true,
                "com.apple.security.application-groups": [FilterService.appGroup(team: profile.team)],
            ]), to: entitlements)
        defer { try? FileManager.default.removeItem(at: entitlements) }
        try sign(
            extensionBundle, identity: identity, identifier: FilterService.extensionIdentifier,
            entitlements: entitlements)
    }
}
