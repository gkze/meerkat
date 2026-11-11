#if DEBUG
    import Foundation
    import MeerkatAgent
    import MeerkatIPC
    import MeerkatKit
    import MeerkatRules

    /// Stands in for meerkatd wherever `AppState` hands out its daemon, so
    /// each page's model, the Event Explorer's and the process card's work
    /// as they do against the real one. Nothing here reaches the installed
    /// daemon, whose rules sample data must never change. Requests no page
    /// sends in sample mode are refused.
    actor SampleDaemon: DaemonConnection {
        /// Sample rules, with the toggles made in this session.
        private var rules = SampleData.rules
        private var droppedReported = false
        private let started = Date()

        func send(_ request: DaemonRequest) async throws -> DaemonReply {
            switch request {
            case .rules, .reloadRules:
                return .rules(rules)
            case .setRuleEnabled(let id, let enabled):
                rules = SampleData.settingEnabled(id, enabled, in: rules)
                return .rules(rules)
            case .ruleLogs(let rule, _):
                return .logs(rule.map { rule in SampleData.logs(for: rule).filter { $0.rule == rule } } ?? [])
            case .status:
                return .status(SampleData.status(uptime: Date().timeIntervalSince(started)))
            case .dryRun(let request):
                try await Task.sleep(for: .seconds(2))
                return .dryRun(SampleData.dryRun(request))
            case .catalog:
                return .catalog(CatalogEntry.entries())
            default:
                throw DaemonClient.ClientError.unexpectedReply("\(request) has no sample reply")
            }
        }

        func subscribe(_ kind: String, parameters: JSONValue) async throws
            -> AsyncThrowingStream<EventEnvelope, any Error>
        {
            // Reported once, however often the Daemon health page returns.
            if kind == MeerkatDroppedEvent.descriptor.name, !droppedReported {
                droppedReported = true
                return SampleData.droppedEvents()
            }
            return SampleData.events(kind, parameters: parameters)
        }
    }

    /// Realistic replies for the Overview, Rules and Daemon health pages, for
    /// debug builds launched with `MEERKAT_SAMPLE_DATA=1`: a way to see every
    /// populated state without a running daemon.
    /// Written as the daemon's JSON, so the fixtures exercise the same
    /// decoding as real replies.
    enum SampleData {
        static let isEnabled = ProcessInfo.processInfo.environment["MEERKAT_SAMPLE_DATA"] != nil
        /// The Mac's name the Overview shows in place of the real one.
        static let host = "studio.local"

        private static let now = Date().timeIntervalSince1970 * 1000

        /// The rules folder the sample daemon reports, and so the one the
        /// editor and "Make a Rule…" write to: a scratch folder, never the
        /// installed daemon's, which would load what is saved there. It
        /// holds the files `rules` names, and the editor support the daemon
        /// would write, so the editor, Open File and the language server see
        /// what the report says.
        static let rulesDirectory: URL = {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Meerkat Sample Rules")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Only where missing: the folder outlives the app, with the
            // edits made in it.
            for (file, text) in sources {
                try? RuleFileSource.create(folder.appendingPathComponent(file), text: text)
            }
            let support = EditorSupport(
                declarations: TypeScriptDeclarations.render(),
                runtimeDeclarations: TypeScriptToolchain.locate()?.runtimeDeclarations.flatMap {
                    try? String(contentsOf: $0, encoding: .utf8)
                },
                configurationSchema: nil, linter: nil)
            Task.detached { try? await support.write(in: folder) }
            return folder
        }()

        /// The rule files `rules` reports, by name: each defines the rules
        /// listed for it, or, for index.ts and scratch.ts, fails as listed.
        static let sources: [(file: String, text: String)] = [
            (
                "low-battery.ts",
                """
                import { rule } from "meerkat";

                export const warn = rule({
                  name: "warn",
                  on: "battery.sample",
                  params: { interval: 60 },
                  handle(event, ctx) {
                    if (event.externalConnected === false) ctx.warn("on battery, drawing", event.systemPowerWatts, "W");
                  },
                });

                """
            ),
            (
                "heavy-writers.ts",
                """
                import { rule } from "meerkat";

                // Processes this user owns that write more than 48 MB a second over a
                // ranking window are logged, so a backup or an indexer that slows the Mac
                // down shows up in the rule's log.

                export const renice = rule({
                  name: "renice",
                  on: "process.top",
                  params: { interval: 5, ioCount: 5 },
                  capabilities: {
                    process: { observe: "own", priority: true },
                  },
                  handle(event, ctx) {
                    let heavy = 0;
                    for (const row of event.io) {
                      // Other users' processes report no disk writes.
                      if (row.diskWriteMB === undefined) {
                        continue;
                      }
                      const perSecond = row.diskWriteMB / row.windowSeconds;
                      if (48 < perSecond) {
                        ctx.info(row.name, "is writing", perSecond, "MB/s");
                        heavy += 1;
                      }
                    }
                    // Nothing over the limit this window: say so, so the log shows the
                    // rule is still running.
                    const quiet = heavy === 0;
                    const window = event.rankWindowSeconds;
                    if (quiet) ctx.info("nothing over the limit in", window, "s");
                  },
                });

                """
            ),
            (
                "downloads.ts",
                """
                import { rule } from "meerkat";

                export const tidy = rule({
                  name: "tidy",
                  on: "fs.change",
                  params: { paths: ["~/Downloads"] },
                  capabilities: { fs: { read: ["~/Downloads"] } },
                  handle(event, ctx) {
                    ctx.info(event.path, event.changes.join(", "));
                  },
                });

                """
            ),
            (
                "microphone.ts",
                """
                import { rule } from "meerkat";

                export const notify = rule({
                  name: "notify",
                  on: "audio.inUse",
                  capabilities: { observe: { allow: ["audio.inUse"] }, notify: true },
                  handle(event, ctx) {
                    // Which device is recording: the first one in use.
                    const used = event.running[0]!;
                    ctx.info(used.device.name ?? "a device", "is in use");
                  },
                });

                """
            ),
            (
                "recorder.ts",
                """
                import { rule } from "meerkat";

                export const continuous = rule({
                  name: "continuous",
                  on: "timer",
                  params: { every: 60 },
                  handle(_event, ctx) {
                    ctx.info("recording");
                  },
                });

                """
            ),
            (
                "index.ts",
                """
                import { rule } from "meerkat";

                rule({
                  name: "pinger",
                  on: "timer",
                  params: { every: 60 },
                  handle(_event, ctx) {
                    ctx.info("ping");
                  },
                });

                """
            ),
            (
                "scratch.ts",
                """
                import { rule } from "meerkat";

                export const scratch = rule({
                  name: "scratch",
                  on: "timer",
                  params: { every: 60 },
                  handle(_event, ctx) {
                    ctx.info(limit());
                  },
                });

                // A typing mistake, for the compiler to find.
                function limit(): number {
                  const value: number = "48";
                  return value;
                }

                """
            ),
        ]

        static let rules: RulesReport = decode(
            """
            {
              "rulesDirectory": "\(rulesDirectory.path)",
              "compiledAt": \(now - 95_000),
              "rules": [
                {"id": "low-battery.ts#warn", "file": "low-battery.ts", "event": "battery.sample", "state": "loaded",
                 "invocations": 214, "failures": 0, "lastInvokedAt": \(now - 42_000)},
                {"id": "heavy-writers.ts#renice", "file": "heavy-writers.ts", "event": "process.top", "state": "loaded",
                 "invocations": 1893, "failures": 3, "lastInvokedAt": \(now - 4_000),
                 "lastError": "exec: /usr/bin/renice exited 1: Operation not permitted"},
                {"id": "downloads.ts#tidy", "file": "downloads.ts", "event": "fs.change", "state": "disabled",
                 "reason": "turned off with meerkat rules disable", "invocations": 57, "failures": 0,
                 "lastInvokedAt": \(now - 7_200_000)},
                {"id": "microphone.ts#notify", "file": "microphone.ts", "event": "audio.inUse", "state": "failed",
                 "reason": "circuit breaker: 5 failures in a row", "invocations": 12, "failures": 5,
                 "lastInvokedAt": \(now - 600_000), "lastError": "TypeError: Cannot read properties of undefined (reading 'device')"},
                {"id": "recorder.ts#continuous", "file": "recorder.ts", "event": "timer", "state": "loaded",
                 "invocations": 98, "failures": 0, "lastInvokedAt": \(now - 180_000)},
                {"id": "index.ts", "file": "index.ts", "state": "failed",
                 "reason": "index.ts creates rules (pinger) but exports none", "invocations": 0, "failures": 0}
              ],
              "diagnostics": [
                {"tool": "compiler", "kind": "finding", "severity": "error", "file": "scratch.ts", "line": 14,
                 "column": 9, "code": "TS2322", "message": "Type 'string' is not assignable to type 'number'.",
                 "fixable": false},
                {"tool": "loader", "kind": "finding", "severity": "error", "file": "index.ts",
                 "message": "creates rules (pinger) but exports none", "fixable": false}
              ],
              "lint": {
                "lintedAt": \(now - 90_000),
                "diagnostics": [
                  {"tool": "oxlint", "kind": "finding", "severity": "error", "file": "heavy-writers.ts", "line": 22,
                   "column": 11, "code": "eslint(no-magic-numbers)",
                   "message": "No magic number: 48. Name it, for example const WRITE_LIMIT_MB = 48."},
                  {"tool": "oxlint", "kind": "finding", "severity": "warning", "file": "heavy-writers.ts", "line": 31,
                   "column": 5, "code": "eslint(curly)", "message": "Expected { after 'if' condition."},
                  {"tool": "meerkat-lint", "kind": "finding", "severity": "error", "file": "microphone.ts", "line": 9,
                   "column": 18, "code": "meerkat(payload-optional-field)",
                   "message": "event.running may be empty; check its length before reading [0]."},
                  {"tool": "oxfmt", "kind": "finding", "severity": "warning", "file": "downloads.ts",
                   "message": "not formatted; `meerkat rules fmt` formats it", "fixable": true},
                  {"tool": "meerkat-lint", "kind": "toolFailure", "severity": "error",
                   "message": "meerkat-lint did not run: policy file is missing", "fixable": false}
                ]
              }
            }
            """)

        /// Stands in for the agent's registration: each action takes 2 s,
        /// then leaves the status it would, so every action and its
        /// progress can be seen without touching the installed agent.
        @MainActor
        static func agent() -> AgentBackend {
            let registration = SampleRegistration()
            return AgentBackend(
                status: { registration.status },
                run: { action in
                    try await Task.sleep(for: .seconds(2))
                    await registration.finish(action)
                })
        }

        @MainActor
        private final class SampleRegistration: Sendable {
            private(set) var status = AgentRegistration.Status.enabled

            func finish(_ action: AgentControl.Action) {
                status = action == .uninstalling ? .notRegistered : .enabled
            }
        }

        /// `report` with rule `id` turned on or off, as the daemon would
        /// report it. A failed rule stays failed when turned on.
        static func settingEnabled(_ id: String, _ enabled: Bool, in report: RulesReport) -> RulesReport {
            let rules = report.rules.map { rule -> RuleSummary in
                guard rule.id == id, rule.state != .failed || !enabled else { return rule }
                return RuleSummary(
                    id: rule.id, file: rule.file, event: rule.event, state: enabled ? .loaded : .disabled,
                    reason: enabled ? nil : "turned off in Meerkat", invocations: rule.invocations,
                    failures: rule.failures,
                    lastInvokedAt: rule.lastInvokedAt, lastError: rule.lastError)
            }
            return RulesReport(
                rulesDirectory: report.rulesDirectory, rules: rules, diagnostics: report.diagnostics,
                compiledAt: report.compiledAt, lint: report.lint)
        }

        static func logs(for rule: String) -> [RuleLogEntry] {
            let lines: [(String?, Double, String, String)] = [
                (
                    "heavy-writers.ts#renice", 4_000, "warn",
                    "renice 19 for pid 4312 (mds_stores) failed, will retry next window"
                ),
                ("heavy-writers.ts#renice", 64_000, "info", "lowered priority of pid 981 (Xcode) writing 48.2 MB/s"),
                (
                    "heavy-writers.ts#renice", 3_600_000, "error",
                    "heavy-writers.ts#renice held the JavaScript thread for 5.2 s; the handler host restarts"
                ),
                (
                    "microphone.ts#notify", 600_000, "error",
                    "TypeError: Cannot read properties of undefined (reading 'name')"
                ),
                ("microphone.ts", 600_500, "warn", "microphone.ts#notify turned off after 5 failures"),
                ("low-battery.ts#warn", 42_000, "info", "battery at 18%, notified"),
                ("recorder.ts#continuous", 180_000, "debug", "recorded label continuous (20 s window, 20 processes)"),
                ("index.ts", 95_000, "warn", "rules created but not exported by index.ts, so not running: pinger"),
            ]
            let file = RuleID.file(of: rule)
            return lines.filter { $0.0 == rule || $0.0 == file }.map {
                RuleLogEntry(rule: $0.0, time: now - $0.1, level: LogLevel(rawValue: $0.2) ?? .info, message: $0.3)
            }
        }

        /// `uptime` (seconds) advances the delivered counters at each source's
        /// rate.
        static func status(uptime: Double) -> DaemonStatus {
            decode(
                """
                {
                  "version": "0.9.0",
                  "pid": 48213,
                  "startedAt": \(now - 9_480_000),
                  "executablePath": "/Users/example/Applications/Meerkat.app/Contents/Library/LoginItems/Meerkat.app/Contents/MacOS/meerkatd",
                  "rulesDirectory": "\(rulesDirectory.path)",
                  "handlerHost": {"state": "running", "workers": 5, "restarts": 1,
                                  "lastExit": "heavy-writers.ts#renice held the JavaScript thread for 5.2 s"},
                  "sources": [
                    {"instance": 3, "kind": "cpu.sample", "parameters": {"interval": 0.25}, "subscribers": 2,
                     "delivered": \(38_112 + Int(uptime * 4)), "dropped": 0, "unencodable": 0},
                    {"instance": 4, "kind": "memory.sample", "parameters": {"interval": 1}, "subscribers": 1,
                     "delivered": \(9_528 + Int(uptime)), "dropped": 0, "unencodable": 0},
                    {"instance": 7, "kind": "process.top", "parameters": {"count": 3, "interval": 1, "ioCount": 3, "rankInterval": 5},
                     "subscribers": 2, "delivered": \(9_401 + Int(uptime)), "dropped": 0, "unencodable": 0},
                    {"instance": 9, "kind": "fs.change", "parameters": {"latency": 0.1, "paths": ["/Users/example/Downloads"]},
                     "subscribers": 1, "delivered": \(1_204 + Int(uptime * 18.5)), "dropped": 312, "unencodable": 0},
                    {"instance": 11, "kind": "battery.sample", "parameters": {}, "subscribers": 1, "delivered": 214, "dropped": 0,
                     "unencodable": 2, "lastUnencodable": "systemPowerWatts is NaN"},
                    {"instance": 12, "kind": "timer", "parameters": {"every": 300}, "subscribers": 1, "delivered": 98, "dropped": 0, "unencodable": 0},
                    {"instance": 13, "kind": "log.entry", "parameters": {"level": "default", "predicate": "subsystem == \\"com.apple.bluetooth\\""},
                     "subscribers": 1, "delivered": 57, "dropped": 0, "unencodable": 0,
                     "detail": "log applies: subsystem == \\"com.apple.bluetooth\\" AND type == 1024"}
                  ],
                  "rules": \(encoded(rules.rules)),
                  "configuration": \(encoded(configuration))
                }
                """)
        }

        /// No meerkat.json, so every default applies: encoded from
        /// `MeerkatConfiguration` itself, so the fixture cannot drift from it.
        private static let configuration = ConfigurationStatus(
            file: "/Users/example/.config/meerkat/rules/meerkat.json", source: .defaults,
            effective: MeerkatConfiguration(), problem: nil, appliedAt: now - 9_480_000)

        private static func encoded(_ value: some Encodable) -> String {
            do {
                return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            } catch {
                fatalError("sample data does not encode: \(error)")
            }
        }

        /// Two `meerkat.dropped` reports from the last minute, oldest first,
        /// on a subscription that then stays open: one from a rule file, one
        /// from a client, which reports no file.
        static func droppedEvents() -> AsyncThrowingStream<EventEnvelope, any Error> {
            let parameters = JSONValue.object([
                "latency": .number(0.1), "paths": .array([.string("/Users/example/Downloads")]),
            ])
            return AsyncThrowingStream { continuation in
                for (dropped, file, secondsAgo) in [(100.0, "downloads.ts", 47.0), (212, nil, 12)] {
                    var payload: [String: JSONValue] = [
                        "kind": .string("fs.change"), "parameters": parameters, "dropped": .number(dropped),
                    ]
                    payload["file"] = file.map(JSONValue.string)
                    continuation.yield(
                        envelope(
                            MeerkatDroppedEvent.descriptor.name, payload: .object(payload),
                            time: (Date().timeIntervalSince1970 - secondsAgo) * 1000))
                }
            }
        }

        private static func envelope(_ kind: String, payload: JSONValue, time: Double) -> EventEnvelope {
            EventEnvelope(kind: kind, sequence: 1, time: time, origin: .system, replayed: false, payload: payload)
        }

        // MARK: - Overview feed

        /// Stands in for one daemon subscription, so the Overview's charts move
        /// without a running daemon. Payloads arrive at the cadence the
        /// subscription asks for (`interval`, else `every`; once for push
        /// events, as a state replay), built as JSON and decoded by the
        /// subscriber like real event payloads. A kind with no feed stays
        /// open and silent, like a source with nothing to report.
        static func events(_ kind: String, parameters: JSONValue) -> AsyncThrowingStream<EventEnvelope, any Error> {
            let period = parameters["interval"]?.numberValue ?? parameters["every"]?.numberValue
            // The ranking window: process.top's rankInterval, process.list's
            // interval (it lists once per ranking).
            let rankInterval = parameters["rankInterval"]?.numberValue ?? period ?? 5
            return AsyncThrowingStream { continuation in
                let task = Task {
                    var tick = 0
                    repeat {
                        let seconds = Double(tick) * (period ?? 0)
                        guard
                            let payload = feedPayload(
                                kind, seconds: seconds, rankInterval: rankInterval, parameters: parameters)
                        else {
                            return
                        }
                        continuation.yield(
                            envelope(kind, payload: payload, time: Date().timeIntervalSince1970 * 1000))
                        tick += 1
                        guard let period else { return }  // push: stays open, like a subscription
                        try? await Task.sleep(for: .seconds(period))
                    } while !Task.isCancelled
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        /// The sample processes' names, by pid, as the feeds list them.
        private static let names: [Int32: String] = [
            980: "Xcode", 412: "WindowServer", 377: "mds_stores", 1204: "Safari", 0: "kernel_task", 1388: "Mail",
            1502: "Notes", 611: "Finder", 1730: "Terminal", 1811: "Music", 1920: "Calendar", 2044: "Preview",
            1: "launchd",
        ]

        private static func period(_ parameters: JSONValue) -> Double {
            parameters["interval"]?.numberValue ?? parameters["every"]?.numberValue ?? 1
        }

        private static let physicalMB = Double(ProcessInfo.processInfo.physicalMemory) / 1_000_000
        private static let cpuCount = ProcessInfo.processInfo.processorCount

        /// Slow waves plus jitter, so consecutive samples differ by realistic
        /// steps and the charts have something to animate between.
        private static func wave(
            _ t: Double, _ base: Double, _ swings: [(amplitude: Double, period: Double)], jitter: Double
        )
            -> Double
        {
            swings.reduce(base) { $0 + $1.amplitude * sin(t / $1.period) } + Double.random(in: -jitter...jitter)
        }

        private static func process(
            _ pid: Int32, _ name: String, cpu: Double, writeMB: Double, readMB: Double, window: Double,
            footprintMB: Double = 420
        )
            -> JSONValue
        {
            .object([
                "pid": .number(Double(pid)), "name": .string(name), "cpuPct": .number(cpu),
                "cpuSeconds": .number(cpu / 100 * window), "windowSeconds": .number(window),
                "footprintMB": .number(footprintMB), "diskReadMB": .number(readMB), "diskWriteMB": .number(writeMB),
                "energyJoules": .number(cpu / 10),
                // A start time per pid, so each row opens a process card.
                "startedAt": .number(now - Double(pid) * 60_000), "uid": .number(501),
            ])
        }

        private static func feedPayload(
            _ kind: String, seconds t: Double, rankInterval: Double, parameters: JSONValue
        ) -> JSONValue? {
            switch kind {
            case "cpu.sample":
                let usage = min(max(wave(t, 26, [(14, 9), (7, 2.1)], jitter: 3), 2), 97)
                return .object([
                    "usagePercent": .number(usage), "busyCores": .number(usage / 100 * Double(cpuCount)),
                    "cpuCount": .number(Double(cpuCount)), "load1": .number(usage / 100 * Double(cpuCount) * 1.2),
                    "load5": .number(3.1), "load15": .number(2.8),
                ])
            case "memory.sample":
                let wired = physicalMB * 0.13
                let compressed = physicalMB * 0.14 + wave(t, 0, [(260, 17), (90, 4)], jitter: 25)
                let active = physicalMB * 0.33 + wave(t, 0, [(400, 11)], jitter: 60)
                let inactive = physicalMB * 0.22
                return .object([
                    "pageSize": .number(16384), "wiredMB": .number(wired), "compressedMB": .number(compressed),
                    "activeMB": .number(active), "inactiveMB": .number(inactive),
                    "freeMB": .number(max(physicalMB - wired - compressed - active - inactive, 0)),
                    "swapUsedMB": .number(1_850), "swapTotalMB": .number(3_072),
                ])
            case "memory.pressure":
                return .object(["level": .string("normal")])
            case "network.path":
                return .object([
                    "status": .string("satisfied"),
                    "interfaces": .array([.object(["name": .string("en0"), "type": .string("wifi")])]),
                    "isExpensive": .bool(false), "isConstrained": .bool(false), "supportsIPv4": .bool(true),
                    "supportsIPv6": .bool(true), "supportsDNS": .bool(true),
                ])
            case "power.assertions":
                return .object([
                    "assertions": .array([
                        .object([
                            "id": .number(38_069), "pid": .number(1204), "process": .string("Safari"),
                            "type": .string("PreventUserIdleDisplaySleep"), "name": .string("Playing video"),
                            "startedAt": .number(now - 1_260_000),
                        ]),
                        .object([
                            "id": .number(34_211), "pid": .number(639), "process": .string("coreaudiod"),
                            "type": .string("PreventUserIdleSystemSleep"), "onBehalfOfPid": .number(1811),
                        ]),
                    ]),
                    "active": .array([.string("PreventUserIdleDisplaySleep"), .string("PreventUserIdleSystemSleep")]),
                ])
            case "disk.sample":
                // disk4 is a disk image: its I/O also crosses disk0, so it is
                // in the rows but not the totals.
                let write = max(wave(t, 14, [(11, 19), (5, 6)], jitter: 4), 0.2) * 1e6
                let read = max(wave(t, 6, [(5, 13)], jitter: 2), 0.1) * 1e6
                func disk(_ name: String, virtual: Bool, read: Double, write: Double) -> JSONValue {
                    .object([
                        "bsdName": .string(name), "isVirtual": .bool(virtual),
                        "readBytesPerSecond": .number(read), "writeBytesPerSecond": .number(write),
                        "readsPerSecond": .number(read / 65_536), "writesPerSecond": .number(write / 65_536),
                        "readLatencyMs": .number(0.09), "writeLatencyMs": .number(0.03), "errors": .number(0),
                    ])
                }
                return .object([
                    "disks": .array([
                        disk("disk0", virtual: false, read: read, write: write),
                        disk("disk4", virtual: true, read: read * 0.2, write: 0),
                    ]),
                    "readBytesPerSecond": .number(read), "writeBytesPerSecond": .number(write),
                ])
            case "network.sample":
                let received = max(wave(t, 900_000, [(700_000, 15), (250_000, 3)], jitter: 80_000), 2_000)
                let sent = max(wave(t, 60_000, [(40_000, 9)], jitter: 8_000), 500)
                func interface(_ name: String, received: Double, sent: Double) -> JSONValue {
                    .object([
                        "name": .string(name), "receivedBytesPerSecond": .number(received),
                        "sentBytesPerSecond": .number(sent), "receivedPacketsPerSecond": .number(received / 1_400),
                        "sentPacketsPerSecond": .number(sent / 600), "errors": .number(0),
                    ])
                }
                return .object([
                    "interfaces": .array([
                        interface("en0", received: received, sent: sent),
                        interface("lo0", received: 12_000, sent: 12_000),
                        interface("utun4", received: received * 0.4, sent: sent * 0.5),
                    ]),
                    "receivedBytesPerSecond": .number(received), "sentBytesPerSecond": .number(sent),
                ])
            case "battery.sample":
                let load = max(wave(t, 24, [(9, 40), (4, 7)], jitter: 1.5), 4)
                return .object([
                    "cycleCount": .number(340), "designCycleCount": .number(1000), "healthPercent": .number(85.2),
                    "designCapacityMAh": .number(8579), "fullChargeCapacityMAh": .number(7313),
                    "voltage": .number(12.4), "amperage": .number(3.1), "systemPowerWatts": .number(load),
                    "externalConnected": .bool(true), "adapterWatts": .number(140),
                ])
            case "power.source":
                return .object([
                    "providing": .string("ac"), "warningLevel": .string("none"),
                    "batteries": .array([
                        .object([
                            "name": .string("InternalBattery-0"), "currentCapacityPercent": .number(60),
                            "isCharging": .bool(true), "timeToFullMinutes": .number(56),
                            "powerSourceState": .string("ac"),
                        ])
                    ]),
                ])
            case "thermal.state":
                return .object(["state": .string("fair")])
            case "power.lowPowerMode":
                return .object(["enabled": .bool(false)])
            case "process.top":
                // Disk rates and the I/O ranking change once per rank window,
                // as the daemon's do; CPU rows refresh every sample.
                let ranked = (t / rankInterval).rounded(.down) * rankInterval
                let write = max(wave(ranked, 14, [(11, 19), (5, 6)], jitter: 4), 0.2)
                let read = max(wave(ranked, 6, [(5, 13)], jitter: 2), 0.1)
                let cpu: [JSONValue] = [
                    ("Xcode", 980, 62.0), ("WindowServer", 412, 21.0), ("mds_stores", 377, 12.0),
                    ("Safari", 1204, 9.0), ("kernel_task", 0, 7.0),
                ].map {
                    process(
                        $0.1, $0.0, cpu: max(wave(t + Double($0.1), $0.2, [($0.2 / 3, 5)], jitter: 2), 0.1),
                        writeMB: 0, readMB: 0, window: 1)
                }
                let io: [JSONValue] = [
                    process(
                        377, "mds_stores", cpu: 12, writeMB: write * 0.55 * rankInterval,
                        readMB: read * 0.5 * rankInterval, window: rankInterval),
                    process(
                        980, "Xcode", cpu: 62, writeMB: write * 0.3 * rankInterval, readMB: read * 0.3 * rankInterval,
                        window: rankInterval),
                    process(
                        1204, "Safari", cpu: 9, writeMB: write * 0.15 * rankInterval, readMB: read * 0.2 * rankInterval,
                        window: rankInterval),
                ]
                let memory: [JSONValue] = [
                    ("Xcode", 980, 6_400.0), ("Safari", 1204, 2_150.0), ("WindowServer", 412, 1_380.0),
                    ("mds_stores", 377, 310.0),
                ].map {
                    process(
                        $0.1, $0.0, cpu: 5, writeMB: 0, readMB: 0, window: rankInterval,
                        footprintMB: $0.2 + wave(ranked, 0, [($0.2 / 20, 30)], jitter: 0))
                }
                return .object([
                    "cpu": .array(cpu), "io": .array(io), "memory": .array(memory), "diskReadMBps": .number(read),
                    "diskWriteMBps": .number(write), "rankWindowSeconds": .number(rankInterval),
                    "rankedAt": .number(now + ranked * 1000),
                ])
            case "process.list":
                // Every process, as the daemon lists it: busy ones, idle
                // ones, and other users' with CPU time only.
                let window = rankInterval
                let own: [JSONValue] =
                    ([
                        ("Xcode", 980, 58.0, 6_400.0, 4.1), ("WindowServer", 412, 21.0, 1_380.0, 0),
                        ("Safari", 1204, 9.0, 2_150.0, 1.2), ("Mail", 1388, 0.4, 290.0, 0.1),
                        ("Notes", 1502, 0, 180.0, 0), ("Finder", 611, 0.2, 140.0, 0),
                        ("Terminal", 1730, 1.1, 120.0, 0), ("Music", 1811, 0, 95.0, 0),
                        ("Calendar", 1920, 0, 88.0, 0), ("Preview", 2044, 0, 64.0, 0),
                    ] as [(String, Int32, Double, Double, Double)]).map {
                        let cpu = $0.2 == 0 ? 0 : max(wave(t + Double($0.1), $0.2, [($0.2 / 3, 7)], jitter: 1), 0.1)
                        return process(
                            $0.1, $0.0, cpu: cpu, writeMB: $0.4 * window, readMB: $0.4 * 0.6 * window, window: window,
                            footprintMB: $0.3)
                    }
                let others: [JSONValue] =
                    ([("mds_stores", 377, 12.0), ("kernel_task", 0, 7.0), ("launchd", 1, 0.1)]
                    as [(String, Int32, Double)]).map {
                        .object([
                            "pid": .number(Double($0.1)), "name": .string($0.0), "cpuPct": .number($0.2),
                            "cpuSeconds": .number($0.2 / 100 * window), "windowSeconds": .number(window),
                            "startedAt": .number(now - 9_000_000), "uid": .number(0),
                        ])
                    }
                return .object(["processes": .array(own + others)])
            case "process.sample":
                // The process a card opened, by the pid it asked for: a
                // sample one, under its sample name.
                let pid = Int32(exactly: parameters["pid"]?.numberValue ?? 0) ?? 0
                let name = names[pid] ?? "process \(pid)"
                let cpu = max(wave(t + Double(pid), 8, [(5, 6), (2, 1.7)], jitter: 1), 0.1)
                return .object([
                    "running": .bool(true),
                    "process": process(
                        pid, name, cpu: cpu, writeMB: max(wave(t, 1.2, [(1, 9)], jitter: 0.2), 0), readMB: 0.4,
                        window: period(parameters), footprintMB: 640 + wave(t, 0, [(40, 20)], jitter: 4)),
                ])
            case "fs.churn":
                let scale = 1 + 0.3 * sin(t / 50)
                let buckets: [(String, Double)] = [
                    ("~/Library/Developer/Xcode/DerivedData", 812), ("~/Library/Caches/com.apple.Safari", 344),
                    ("~/Library/Application Support/Example", 191), ("~/Library/Containers/com.apple.mail", 77),
                ]
                let counts = buckets.map { Int($0.1 * scale) }
                let total = counts.reduce(0, +)
                return .object([
                    "root": .string(NSHomeDirectory() + "/Library"), "windowSeconds": .number(4),
                    "totalEvents": .number(Double(total)), "created": .number(Double(total / 5)),
                    "modified": .number(Double(total * 3 / 4)), "removed": .number(Double(total / 20)),
                    "renamed": .number(0),
                    "buckets": .array(
                        zip(buckets, counts).map {
                            .object(["path": .string($0.0.0), "events": .number(Double($0.1))])
                        }),
                    "categories": .array([]),
                    "excluded": .array([.string(NSHomeDirectory() + "/Library/Logs")]),
                ])
            default:
                return nil
            }
        }

        /// A run of three events: nothing to do, a notification, and one
        /// `match` skips. Given events each get a plain row.
        static func dryRun(_ request: DryRunRequest) -> DryRunReport {
            func event(_ providing: String, _ percent: Double, secondsAgo: Double) -> EventEnvelope {
                EventEnvelope(
                    kind: "power.source", sequence: 1, time: now - secondsAgo * 1000, origin: .system, replayed: false,
                    payload: .object([
                        "providing": .string(providing),
                        "batteries": .array([.object(["currentCapacityPercent": .number(percent)])]),
                    ]))
            }
            let notify = DryRunEffect(
                kind: "notify",
                request: .object(["id": .string("low-battery"), "title": .string("Battery low")]),
                outcome: .simulated(result: .null))
            let state = DryRunEffect(
                kind: "state.get", request: .object(["key": .string("warned")]), outcome: .read(result: .bool(false)))
            var runs = [
                DryRunInvocation(event: event("battery", 16, secondsAgo: 42), result: .completed, milliseconds: 1.8),
                DryRunInvocation(
                    event: event("battery", 14, secondsAgo: 13), result: .completed, effects: [state, notify],
                    logs: [DryRunLog(level: .info, message: "warned at 14 %")], milliseconds: 3.2),
                DryRunInvocation(
                    event: event("ac", 14, secondsAgo: 2), result: .skipped(reason: "match: providing isn't battery")),
            ]
            if case .given(let events) = request.events {
                runs = events.map { given in
                    DryRunInvocation(
                        event: EventEnvelope(
                            kind: "power.source", sequence: 1, time: given.time ?? now, origin: given.origin ?? .system,
                            replayed: false, payload: given.payload),
                        result: .completed, milliseconds: 1.2)
                }
            }
            return DryRunReport(
                outcome: .ran, rules: ["warn"], rule: RuleID.make(file: request.file, name: "warn"),
                event: "power.source", runs: runs, compileMilliseconds: 180, loadMilliseconds: 42)
        }

        private static func decode<T: Decodable>(_ json: String) -> T {
            do {
                return try JSONDecoder().decode(T.self, from: Data(json.utf8))
            } catch {
                fatalError("sample data does not decode as \(T.self): \(error)")
            }
        }
    }
#endif
