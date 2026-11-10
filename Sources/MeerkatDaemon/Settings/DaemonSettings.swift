import Foundation
import MeerkatIPC
import MeerkatKit
import MeerkatStore
import Synchronization
import os

/// `meerkat.json` as the daemon applies it (`MeerkatConfiguration`).
///
/// The rule engine calls `reload` when the file changes, beside, never
/// inside, the rule compile: the file is data validated against its schema,
/// so a rule with a type error cannot hold back a policy change, and no
/// toolchain is needed to apply one.
///
/// A file that fails validation changes nothing: the last version that
/// applied stays in force, and the problem is reported with the rule
/// diagnostics, so a broken edit can never leave the policy wider than it
/// was. With no file, every default applies; at start, an invalid file also
/// leaves the defaults, which are the policy's fail-closed baseline.
final class DaemonSettings: Sendable {
    let file: URL
    private let catalog: EventCatalog
    private let state: Mutex<ConfigurationStatus>
    private let logger = Logger(subsystem: DaemonService.label, category: "settings")

    init(rulesDirectory: URL, catalog: EventCatalog) {
        file = DaemonPaths.configurationFile(in: rulesDirectory)
        self.catalog = catalog
        state = Mutex(
            ConfigurationStatus(
                file: file.path, source: .defaults, effective: MeerkatConfiguration(), problem: nil,
                appliedAt: Date().timeIntervalSince1970 * 1000))
    }

    /// What applies now.
    var current: MeerkatConfiguration { state.withLock { $0.effective } }

    var status: ConfigurationStatus { state.withLock { $0 } }

    var policy: MCPPolicy { MCPPolicy(current.mcp) }

    var sampleLimits: SampleStore.Limits { SampleStore.Limits(current.samples) }

    /// The file's problem as a rule diagnostic, for `RulesReport`.
    var diagnostic: RuleDiagnostic? {
        state.withLock { state in
            state.problem.map {
                RuleDiagnostic(
                    tool: .loader, file: MeerkatConfiguration.fileName, code: "meerkat(config)",
                    message: state.source == .lastGood
                        ? "\($0); the previous version still applies" : "\($0); the defaults apply")
            }
        }
    }

    /// Reads the file and applies it when it is valid.
    func reload() {
        let now = Date().timeIntervalSince1970 * 1000
        let path = file.path
        let next: (MeerkatConfiguration?, String?)
        do {
            let data = try Data(contentsOf: file)
            next = (try MeerkatConfiguration.decode(data, catalog: catalog), nil)
        } catch CocoaError.fileReadNoSuchFile {
            next = (MeerkatConfiguration(), nil)
        } catch let invalid as MeerkatConfiguration.Invalid {
            next = (nil, invalid.description)
        } catch {
            next = (nil, "cannot read it: \(error.localizedDescription)")
        }
        let exists = FileManager.default.fileExists(atPath: path)
        let (changed, problem) = state.withLock { state -> (Bool, String?) in
            let previous = state
            switch next {
            case (let configuration?, _):
                state = ConfigurationStatus(
                    file: path, source: exists ? .file : .defaults, effective: configuration, problem: nil,
                    appliedAt: configuration == previous.effective ? previous.appliedAt : now)
            case (nil, let problem):
                // Keep what applies; only a version that applied is "last good".
                let source: ConfigurationStatus.Source = previous.source == .defaults ? .defaults : .lastGood
                state = ConfigurationStatus(
                    file: path, source: source, effective: previous.effective, problem: problem,
                    appliedAt: previous.appliedAt)
            }
            return (state != previous, state.problem)
        }
        guard changed else { return }
        if let problem {
            logger.error("\(MeerkatConfiguration.fileName, privacy: .public) not applied: \(problem, privacy: .public)")
        } else {
            logger.info("\(MeerkatConfiguration.fileName, privacy: .public) applied")
        }
    }

    /// The file's JSON Schema and where the rules directory's editor
    /// support keeps it, for `$schema` (`EditorSupport`).
    var schema: (path: String, text: String) {
        (MeerkatConfiguration.schemaPath, MeerkatConfiguration.jsonSchema(catalog))
    }
}
