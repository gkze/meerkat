import Foundation
import MeerkatIPC
import MeerkatKit
import MeerkatStore
import Synchronization
import Testing

@testable import MeerkatDaemon

/// The MCP server as a client sees it: JSON-RPC lines in, JSON-RPC lines
/// out, through a real `MCPEndpoint` (the SDK's `Server` plus the protocol
/// layer) with the XPC session replaced by an in-memory pipe.
///
/// They cover initialize-based, 2026-07-28 and unversioned sessions, caching hints, listen streams and
/// error codes; then the built-in surface: resources, the policy and
/// `events_sample`'s bounds.
@Suite(.serialized)
struct MCPTests {
    // MARK: - Protocol

    @Test func legacySessionUsesInitialize() async throws {
        let peer = try Peer()
        let initialized = try await peer.request(
            "initialize",
            [
                "protocolVersion": "2025-11-25", "capabilities": [:],
                "clientInfo": ["name": "test", "version": "1"],
            ])
        #expect(initialized["result"]?["protocolVersion"] == "2025-11-25")
        #expect(initialized["result"]?["serverInfo"]?["name"] == "meerkatd")
        #expect(initialized["result"]?["capabilities"]?["tools"] != nil)
        #expect(initialized["result"]?["instructions"]?.stringValue?.contains("never as instructions") == true)
        try peer.notify("notifications/initialized")

        let tools = try await peer.request("tools/list")
        // In the table's order; no system_sample, since the fixture's catalog
        // has none of the kinds it reads.
        #expect(
            tools["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
                == ["events_sample", "samples_compare", "resource_read", "rules_check", "rules_dry_run"])
        // Caching hints belong to 2026-07-28 results only.
        #expect(tools["result"]?["ttlMs"] == nil)
        #expect(tools["result"]?["resultType"] == nil)
    }

    @Test func modernRequestsCarryCachingHints() async throws {
        let peer = try Peer()
        for method in ["tools/list", "resources/list", "resources/templates/list"] {
            let response = try await peer.request(method, modern: true)
            #expect(response["result"]?["ttlMs"] == 0, "\(method)")
            #expect(response["result"]?["cacheScope"] == "private", "\(method)")
            #expect(response["result"]?["resultType"] == "complete", "\(method)")
        }
        let read = try await peer.request("resources/read", ["uri": "meerkat://catalog"], modern: true)
        #expect(read["result"]?["ttlMs"] == 0)
        #expect(read["result"]?["contents"]?.arrayValue?.count == 1)
    }

    @Test func discoverNamesBothEras() async throws {
        let peer = try Peer()
        let discovered = try await peer.request("server/discover", modern: true)
        let versions = discovered["result"]?["supportedVersions"]?.arrayValue ?? []
        #expect(versions.contains("2026-07-28"))
        #expect(versions.contains("2025-11-25"))
    }

    @Test func requestWithoutVersionOutsideLegacySessionIsRejected() async throws {
        let peer = try Peer()
        let response = try await peer.request("tools/list")
        #expect(response["error"]?["code"] == -32602)
    }

    @Test func unsupportedVersionIsRejected() async throws {
        let peer = try Peer()
        let response = try await peer.request("tools/list", modern: true, version: "2099-01-01")
        #expect(response["error"]?["code"] == -32022)
    }

    @Test func listenIsAcknowledgedAndTagged() async throws {
        let peer = try Peer()
        let id = try peer.send(
            "subscriptions/listen", ["notifications": ["toolsListChanged": true, "resourcesListChanged": true]],
            modern: true)
        let acknowledged = try await peer.message {
            $0["method"] == "notifications/subscriptions/acknowledged"
        }
        // Nothing is offered yet, so nothing the client asked for is granted.
        #expect(acknowledged["params"]?["notifications"] == [:])
        #expect(acknowledged["params"]?["_meta"]?["io.modelcontextprotocol/subscriptionId"] == .number(Double(id)))
        try peer.notify("notifications/cancelled", ["requestId": .number(Double(id))])
        // The stream ended without a response, and the session still answers.
        let tools = try await peer.request("tools/list", modern: true)
        #expect(tools["result"] != nil)
    }

    @Test func unknownToolIsAProtocolError() async throws {
        let peer = try Peer()
        let response = try await peer.request("tools/call", ["name": "exec", "arguments": [:]], modern: true)
        #expect(response["error"]?["code"] == -32602)
    }

    // MARK: - Rule tools and prompts

    private func tool(_ name: String, _ arguments: JSONValue, on peer: Peer) async throws -> JSONValue {
        let response = try await peer.request(
            "tools/call", ["name": .string(name), "arguments": arguments], modern: true)
        return try #require(response["result"], "\(response)")
    }

    @Test func toolsAreAllReadOnly() async throws {
        let peer = try Peer()
        let response = try await peer.request("tools/list", modern: true)
        let tools = try #require(response["result"]?["tools"]?.arrayValue)
        // No system_sample: the fixture's catalog has none of the kinds it reads.
        #expect(
            tools.compactMap { $0["name"]?.stringValue }
                == ["events_sample", "samples_compare", "resource_read", "rules_check", "rules_dry_run"])
        for tool in tools { #expect(tool["annotations"]?["readOnlyHint"] == true) }
    }

    /// What a caller gets wrong comes back as text a model can act on.
    @Test(arguments: [
        ("rules_check", [:] as JSONValue),
        ("rules_check", ["file": "a.ts"] as JSONValue),
        ("rules_check", ["file": "../a.ts", "text": "export {};"] as JSONValue),
        ("rules_check", ["file": "a.ts", "text": "export {};", "extra": 1] as JSONValue),
        ("rules_dry_run", [:] as JSONValue),
        ("rules_dry_run", ["file": "../../etc/passwd.ts"] as JSONValue),
        ("rules_dry_run", ["file": "lib/a.ts"] as JSONValue),
        ("rules_dry_run", ["file": "missing.ts"] as JSONValue),
        ("rules_dry_run", ["file": "a.ts", "text": "export {};"] as JSONValue),
    ])
    func ruleToolsRefuseWhatIsWrong(name: String, arguments: JSONValue) async throws {
        let peer = try Peer()
        let result = try await tool(name, arguments, on: peer)
        #expect(result["isError"] == true, "\(result)")
    }

    /// The fixture has no runtime or compiler, which is a tool error the
    /// model can read, not a crash.
    @Test func rulesCheckSaysWhenItCannotRun() async throws {
        let peer = try Peer()
        let result = try await tool("rules_check", ["file": "a.ts", "text": "export {};"], on: peer)
        #expect(result["isError"] == true)
        #expect(result["content"]?.arrayValue?.first?["text"]?.stringValue == "no rule runtime is available")
    }

    @Test func promptsAreTheSkills() async throws {
        let peer = try Peer()
        let list = try await peer.request("prompts/list", modern: true)
        let names = list["result"]?["prompts"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(names == AgentSkill.all.map(\.name))
        for skill in AgentSkill.all {
            let prompt = try await peer.request("prompts/get", ["name": .string(skill.name)], modern: true)
            let message = prompt["result"]?["messages"]?.arrayValue?.first
            #expect(message?["role"] == "user")
            #expect(message?["content"]?["text"]?.stringValue == skill.instructions)
        }
        let unknown = try await peer.request("prompts/get", ["name": "other"], modern: true)
        #expect(unknown["error"]?["code"] == -32602)
    }

    /// What the server tells every client at `initialize` names only its
    /// own tools and prompts.
    @Test func instructionsNameRealToolsAndPrompts() {
        let text = MCPService.instructions
        let tools = text.matches(of: /\b[a-z]+_[a-z_]+\b/).map { String($0.0) }
        #expect(!tools.isEmpty)
        for name in tools { #expect(MCPService.toolNames.contains(name), "\(name)") }
        let prompts = text.matches(of: /\bmeerkat-[a-z]+\b/).map { String($0.0) }
        #expect(!prompts.isEmpty)
        for name in prompts { #expect(AgentSkill.named(name) != nil, "\(name)") }
    }

    /// The skills may not name what this server doesn't have.
    @Test func skillsNameRealResourcesAndTools() throws {
        let tools = MCPService.toolNames
        for skill in AgentSkill.all {
            let uris = skill.instructions.matches(of: /`(meerkat:\/\/[^`]+)`/).map { String($0.1) }
            for uri in uris {
                let concrete = uri.replacing(/\{[a-z]+\}/, with: "x")
                #expect(MCPService.Route(concrete) != nil, "\(skill.name): \(uri)")
            }
            let named = skill.instructions.matches(of: /`((?:rules|events|system|samples|resource)_[a-z_]+)`/).map {
                String($0.1)
            }
            #expect(!named.isEmpty)
            for name in named { #expect(tools.contains(name), "\(skill.name): \(name)") }
        }
    }

    // MARK: - system_sample, samples_compare, resource_read

    /// A sample carries what process.top, cpu.sample and memory.sample
    /// do, so it is offered only while the policy allows all three, and a
    /// call is refused while it is hidden.
    @Test func systemSampleNeedsThePolicyToAllowWhatItReads() async throws {
        #expect(SystemSampleTool(policy: .standard, catalog: .standard).deniedKinds.isEmpty)
        let denying = MCPPolicy(.init(events: .init(deny: ["process.*"])))
        let denied = SystemSampleTool(policy: denying, catalog: .standard)
        #expect(denied.deniedKinds == ["process.top"])
        #expect(denied.denial?.contains("denies process.top") == true)

        let peer = try Peer()
        let result = try await tool(SystemSampleTool.name, [:], on: peer)
        #expect(result["isError"] == true)
        #expect(result["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("denies process.top") == true)
    }

    @Test func systemSampleChecksItsArguments() throws {
        let sampler = SystemSampleTool(policy: .standard, catalog: .standard)
        let options = try sampler.request(["window": 2.5, "top": 3, "systemOnly": true])
        #expect(options == SystemSampler.Options(window: 2.5, top: 3, systemOnly: true))
        #expect(try sampler.request([:]) == SystemSampler.Options(window: 10, top: 10))
        for arguments: JSONValue in [
            ["window": 0], ["window": 31], ["top": 0], ["top": 51], ["top": 2.5], ["churn": "~"], ["window": "5"],
        ] {
            #expect(throws: Refusal.self, "\(arguments)") { try sampler.request(arguments) }
        }
        // The window's ceiling is the policy's.
        let short = SystemSampleTool(policy: MCPPolicy(.init(limits: .init(sampleSeconds: 5))), catalog: .standard)
        #expect(try short.request([:]).window == 5)
        #expect(throws: Refusal.self) { try short.request(["window": 6]) }
    }

    @Test func systemSampleMeasuresAWindow() async throws {
        let sample = try await SystemSampler.sample(.init(window: 0.2, top: 3))
        #expect(sample.windowSeconds > 0)
        #expect(sample.processes.count <= 3)
    }

    /// Over JSON-RPC, with the kinds it reads in the catalog: listed with
    /// its schema, and its reply is JSON and the same structured content,
    /// without the host name none of those kinds carries. Denying one of
    /// them takes it off the list.
    @Test func systemSampleOverTheProtocol() async throws {
        let kinds = try SystemSampleTool.kinds.map { try #require(EventCatalog.standard.kind(named: $0)) }
        let peer = try Peer(kinds: kinds)
        let listed = try await peer.request("tools/list", modern: true)
        let tool = try #require(
            listed["result"]?["tools"]?.arrayValue?.first { $0["name"] == .string(SystemSampleTool.name) })
        #expect(tool["inputSchema"]?["properties"]?["window"]?["type"] == "number")
        #expect(tool["inputSchema"]?["additionalProperties"] == false)

        let result = try await self.tool(SystemSampleTool.name, ["window": 0.2, "top": 2], on: peer)
        #expect(result["isError"] == false, "\(result)")
        let output = try #require(result["structuredContent"])
        #expect(output["processes"]?.arrayValue != nil)
        #expect(output["memory"]?["freeMB"] != nil)
        #expect(output["host"] == nil)
        let text = try #require(result["content"]?.arrayValue?.first?["text"]?.stringValue)
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) == output)

        peer.policy = MCPPolicy(.init(events: .init(deny: ["memory.sample"])))
        let narrowed = try await peer.request("tools/list", modern: true)
        #expect(
            narrowed["result"]?["tools"]?.arrayValue?.contains { $0["name"] == .string(SystemSampleTool.name) } == false
        )
    }

    /// The projection drops the field the sample has: if it is renamed,
    /// this fails rather than letting it through.
    @Test func systemSampleReplyLeavesOutTheHostName() throws {
        #expect(try JSONValue(encoding: SystemSample.test(cpu: 1, minute: 0))["host"] == "test-host")
        let reply = try SystemSampleTool.reply(.test(cpu: 1, minute: 0))
        #expect(reply["host"] == nil)
        #expect(reply["cpuCount"] == 10)
    }

    @Test func resourceReadReadsWhatResourcesRead() async throws {
        let peer = try Peer()
        let result = try await tool(MCPService.readToolName, ["uri": "meerkat://catalog/test.tick"], on: peer)
        #expect(result["isError"] == false)
        let text = try #require(result["content"]?.arrayValue?.first?["text"]?.stringValue)
        let resource = try await peer.read("meerkat://catalog/test.tick")
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) == resource)
        // JSON comes back as structured content too, like every tool's reply.
        #expect(result["structuredContent"] == resource)
        // The rule API is TypeScript: text only.
        let types = try await tool(MCPService.readToolName, ["uri": "meerkat://types"], on: peer)
        #expect(types["isError"] == false)
        #expect(types["structuredContent"] == nil)
        #expect(types["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("declare module") == true)
        for uri in ["meerkat://catalog/no.such", "file:///etc/hosts"] {
            #expect(try await tool(MCPService.readToolName, ["uri": .string(uri)], on: peer)["isError"] == true)
        }
        #expect(try await tool(MCPService.readToolName, [:], on: peer)["isError"] == true)
    }

    @Test func samplesCompareComparesTwoLabels() async throws {
        let peer = try Peer()
        let compare = { (arguments: JSONValue) in try await self.tool(MCPService.compareToolName, arguments, on: peer) }
        // Nothing recorded yet, and reading creates nothing.
        #expect(try await compare(["before": "a", "after": "b"])["isError"] == true)
        #expect(!FileManager.default.fileExists(atPath: peer.fixture.paths.sampleDatabase.path))

        let store = try SampleStore(path: peer.fixture.paths.sampleDatabase.path)
        for (minute, (label, cpu)) in [("before", 10.0), ("before", 12), ("after", 30), ("after", 34)].enumerated() {
            try store.insert(label: label, sample: .test(cpu: cpu, minute: minute))
        }
        let result = try await compare(["before": "before", "after": "after"])
        #expect(result["isError"] == false, "\(result)")
        let output = try #require(result["structuredContent"])
        #expect(output["labels"]?.arrayValue?.map { $0["label"] } == ["before", "after"])
        #expect(output["delta"]?["cpu_usage_pct"]?["change"] == 21)
        #expect(output["overlapping"] == [])

        for arguments: JSONValue in [
            ["before": "before", "after": "other"], ["before": "before"],
            ["before": "before", "after": "after", "limit": 0], ["before": "before", "after": "after", "limit": 1.5],
        ] {
            #expect(try await compare(arguments)["isError"] == true, "\(arguments)")
        }
    }

    // MARK: - Resources

    @Test func unknownResourceIsNotFound() async throws {
        let peer = try Peer()
        for uri in ["meerkat://nothing", "meerkat://catalog/no.such", "meerkat://status?limit=3", "file:///etc/hosts"] {
            let response = try await peer.request("resources/read", ["uri": .string(uri)], modern: true)
            #expect(response["error"]?["code"] == -32002, "\(uri)")
        }
    }

    @Test func statusCatalogAndKindRead() async throws {
        let peer = try Peer()
        let status = try await peer.read("meerkat://status")
        #expect(status["pid"] == .number(Double(getpid())))

        let catalog = try await peer.read("meerkat://catalog")
        let entries = catalog.arrayValue ?? []
        #expect(entries.first { $0["descriptor"]?["name"] == "test.tick" }?["sampleable"] == true)
        #expect(entries.first { $0["descriptor"]?["name"] == "test.secret" }?["sampleable"] == false)

        let kind = try await peer.read("meerkat://catalog/test.tick")
        #expect(kind["payload"]?["type"] == "object")
        #expect(kind["payload"]?["required"] == ["n"])
        #expect(kind["payloadExamples"] == [["n": 7]])
    }

    @Test func samplesReadWithoutStoreIsEmptyAndCreatesNothing() async throws {
        let peer = try Peer()
        #expect(try await peer.read("meerkat://samples") == [])
        #expect(try await peer.read("meerkat://samples/continuous") == [])
        #expect(!FileManager.default.fileExists(atPath: peer.fixture.paths.sampleDatabase.path))
    }

    @Test func routesParsePercentEncodedSegments() {
        typealias Route = MCPService.Route
        #expect(Route("meerkat://status") == .status)
        #expect(Route("meerkat://catalog/cpu.sample") == .kind("cpu.sample"))
        let uri = Route.ruleLogsURI("dir/recorder.ts#continuous")
        #expect(uri == "meerkat://rules/dir%2Frecorder.ts%23continuous/logs")
        #expect(Route(uri) == .ruleLogs(rule: "dir/recorder.ts#continuous", limit: nil))
        #expect(Route(uri + "?limit=5") == .ruleLogs(rule: "dir/recorder.ts#continuous", limit: 5))
        #expect(Route("meerkat://samples/a%20b?limit=2") == .sampleLabel("a b", limit: 2))
        for invalid in [
            "meerkat://rules/x/log", "meerkat://rules/x/logs?limit=x", "meerkat://rules/x/logs?other=1",
            "meerkat://catalog/", "meerkat://types?limit=1", "https://status", "meerkat://rules//logs",
        ] {
            #expect(Route(invalid) == nil, "\(invalid)")
        }
    }

    // MARK: - events_sample

    @Test func inputSchemaListsOnlyAllowedKinds() async throws {
        let peer = try Peer()
        let tools = try await peer.request("tools/list", modern: true)
        let tool = try #require(tools["result"]?["tools"]?.arrayValue?.first)
        #expect(tool["inputSchema"]?["properties"]?["kind"]?["enum"] == ["test.tick"])
        #expect(tool["annotations"]?["readOnlyHint"] == true)
        #expect(tool["outputSchema"]?["type"] == "object")
    }

    @Test func sampleStopsAtMaxEvents() async throws {
        let peer = try Peer()
        let result = try await peer.call(["kind": "test.tick", "maxEvents": 3])
        #expect(result["isError"] == false)
        let output = try #require(result["structuredContent"])
        #expect(output["stopped"] == "maxEvents")
        #expect(output["events"]?.arrayValue?.compactMap { $0["payload"]?["n"] } == [0, 1, 2])
        #expect(output["parameters"] == [:])
        // The text block carries the same JSON for clients without structured content.
        let text = try #require(result["content"]?.arrayValue?.first?["text"]?.stringValue)
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) == output)
        // The output matches the schema the tool advertises.
        #expect(SchemaValidator.violations(of: output, against: EventSampler.outputSchema).isEmpty)
        // Its subscription was released.
        #expect(peer.hub.statistics().isEmpty)
    }

    @Test func sampleStopsAtMaxSeconds() async throws {
        let peer = try Peer()
        let output = try #require(
            try await peer.call(["kind": "test.tick", "maxEvents": 50, "maxSeconds": 0.2])["structuredContent"])
        #expect(output["stopped"] == "maxSeconds")
        #expect(output["events"]?.arrayValue?.count == TickEvent.burst)
    }

    @Test func sampleStopsAtOutputLimit() async throws {
        var policy = MCPPolicy.standard
        policy.limits.outputKiB = 1
        let peer = try Peer(policy: policy)
        let output = try #require(
            try await peer.call(["kind": "test.tick", "maxEvents": 50, "maxSeconds": 1])["structuredContent"])
        #expect(output["stopped"] == "outputLimit")
        let count = output["events"]?.arrayValue?.count ?? 0
        #expect(count > 0 && count < TickEvent.burst)
    }

    @Test func sampleRejectsWhatThePolicyDenies() async throws {
        let peer = try Peer()
        for arguments: JSONValue in [
            ["kind": "test.secret"],
            ["kind": "test.tick", "maxEvents": 501],
            ["kind": "test.tick", "maxEvents": 1.5],
            ["kind": "test.tick", "maxSeconds": 31],
            ["kind": "test.tick", "maxSeconds": 0],
            ["kind": "test.tick", "params": ["interval": 1]],
            ["kind": "test.tick", "extra": true],
        ] {
            let result = try await peer.call(arguments)
            #expect(result["isError"] == true, "\(arguments)")
        }
        // No source was started for any of them.
        #expect(TickEvent.started.load(ordering: .relaxed) == 0)
        #expect(peer.hub.statistics().isEmpty)
    }

    /// A policy change (a saved `meerkat.json`) applies to the next request
    /// on a session that is already open.
    @Test func policyChangesApplyToTheNextRequest() async throws {
        let peer = try Peer()
        #expect(try await peer.call(["kind": "test.tick", "maxEvents": 1])["isError"] == false)
        peer.policy = MCPPolicy(.init(events: .init(deny: ["test.*"])))
        #expect(try await peer.call(["kind": "test.tick", "maxEvents": 1])["isError"] == true)
        let catalog = try await peer.read("meerkat://catalog")
        #expect(catalog.arrayValue?.allSatisfy { $0["sampleable"] == false } == true)

        peer.policy = MCPPolicy(.init(limits: .init(sampleEvents: 2)))
        #expect(try await peer.call(["kind": "test.tick", "maxEvents": 3])["isError"] == true)
        let tools = try await peer.request("tools/list", modern: true)
        let maxEvents = tools["result"]?["tools"]?.arrayValue?.first?["inputSchema"]?["properties"]?["maxEvents"]
        #expect(maxEvents?["maximum"] == 2)
        #expect(maxEvents?["default"] == 2)
        // Leaving maxEvents out stays valid under a ceiling below the default.
        let capped = try await peer.call(["kind": "test.tick"])
        #expect(capped["isError"] == false)
        #expect(capped["structuredContent"]?["events"]?.arrayValue?.count == 2)
    }

    /// Allowing a kind that needs a privacy permission does not make MCP
    /// prompt for it: without the grant the sample fails before any source
    /// starts.
    @Test func allowedPermissionKindWithoutGrantFailsWithoutPrompting() async throws {
        // Injected: a real status depends on what launched the tests, because
        // Accessibility follows the responsible process.
        let peer = try Peer(
            policy: MCPPolicy(.init(events: .init(allow: ["test.secret"]))), permissionStatus: { _ in .denied })
        let tools = try await peer.request("tools/list", modern: true)
        #expect(
            tools["result"]?["tools"]?.arrayValue?.first?["inputSchema"]?["properties"]?["kind"]?["enum"]
                == ["test.tick", "test.secret"])
        let result = try await peer.call(["kind": "test.secret"])
        #expect(result["isError"] == true)
        let text = result["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(text.contains("Accessibility"))
        #expect(peer.hub.statistics().isEmpty)
    }

    @Test func configResourceShowsWhatApplies() async throws {
        let peer = try Peer()
        let config = try await peer.read("meerkat://config")
        #expect(config["source"] == "defaults")
        #expect(config["effective"]?["mcp"]?["limits"]?["sampleEvents"] == 500)
    }

    @Test func concurrentSamplesAreBoundedPerSession() async throws {
        var policy = MCPPolicy.standard
        policy.limits.concurrentSamples = 1
        let peer = try Peer(policy: policy)
        let first = try peer.send(
            "tools/call",
            ["name": "events_sample", "arguments": ["kind": "test.tick", "maxEvents": 50, "maxSeconds": 3]],
            modern: true)
        // The first sample holds its slot once its subscription exists.
        #expect(try await eventually(2) { !peer.hub.statistics().isEmpty })
        let second = try await peer.call(["kind": "test.tick", "maxSeconds": 0.1])
        #expect(second["isError"] == true)
        let finished = try await peer.response(to: first)
        #expect(finished["result"]?["isError"] == false)
    }

    @Test func closingTheSessionStopsItsSamples() async throws {
        let peer = try Peer()
        _ = try peer.send(
            "tools/call",
            ["name": "events_sample", "arguments": ["kind": "test.tick", "maxEvents": 50, "maxSeconds": 30]],
            modern: true)
        #expect(try await eventually(5) { !peer.hub.statistics().isEmpty })
        await peer.endpoint.close()
        // Stopping cancels the handler; its subscription is released as the
        // cancelled task unwinds, well before the sample's 30 seconds.
        let deadline = ContinuousClock.now + .seconds(2)
        while !peer.hub.statistics().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(peer.hub.statistics().isEmpty)
    }
}

// MARK: - Fixtures

/// A `state` kind whose source emits `burst` events as it starts.
enum TickEvent: EventKind {
    typealias Parameters = NoParameters
    static let burst = 30
    static let started = Atomic<Int>(0)

    struct Payload: EventPayload, Equatable {
        var n: Int
        static var schema: TypeSchema { .object(ObjectSchema([.field("n", Int.self)])) }
        static var examples: [Self] { [Self(n: 7)] }
    }

    static let descriptor = EventDescriptor(
        "test.tick", "test", mechanism: .push, semantics: .state, loss: .none, observation: .open, source: "test")

    static func makeSource(
        _ parameters: Parameters, environment: SourceEnvironment, emit: Emitter<Payload>
    ) throws -> any EventSource {
        TickSource(emit: emit)
    }

    final class TickSource: EventSource {
        let emit: Emitter<Payload>
        init(emit: Emitter<Payload>) { self.emit = emit }
        func start() throws {
            TickEvent.started.add(1, ordering: .relaxed)
            for n in 0..<TickEvent.burst { emit(.init(n: n)) }
        }
        func stop() {}
    }
}

/// A kind the standard policy denies: it needs a privacy permission.
enum SecretEvent: EventKind {
    typealias Parameters = NoParameters
    typealias Payload = EmptyPayload

    static let descriptor = EventDescriptor(
        "test.secret", "test", mechanism: .push, semantics: .occurrence, loss: .none,
        permission: .required(.accessibility),
        observation: .open, source: "test")

    static func makeSource(
        _ parameters: Parameters, environment: SourceEnvironment, emit: Emitter<Payload>
    ) throws -> any EventSource {
        Issue.record("the policy should keep test.secret from starting")
        throw EventError.sourceUnavailable("test")
    }
}

/// A daemon without rules or a listener, for its rule engine and paths.
struct MCPFixture {
    let paths: DaemonPaths
    let daemon: Daemon

    init() throws {
        let root = temporaryURL("meerkatd-mcp")
        paths = DaemonPaths(
            rulesDirectory: root.appendingPathComponent("rules"),
            cacheDirectory: root.appendingPathComponent("cache"),
            ruleDatabase: root.appendingPathComponent("rules.db"),
            sampleDatabase: root.appendingPathComponent("samples.db"))
        try FileManager.default.createDirectory(at: paths.rulesDirectory, withIntermediateDirectories: true)
        daemon = try Daemon(paths: paths, runtime: nil, toolchain: nil, lintToolchain: nil)
    }
}

/// One MCP client on one endpoint.
final class Peer: Sendable {
    let fixture: MCPFixture
    let hub: EventHub
    let endpoint: MCPEndpoint
    private let inbox = Inbox()
    private let ids = Atomic<Int>(0)
    /// The policy the service reads on each request, as `meerkat.json` would set it.
    private let currentPolicy: Mutex<MCPPolicy>

    var policy: MCPPolicy {
        get { currentPolicy.withLock { $0 } }
        set { currentPolicy.withLock { $0 = newValue } }
    }

    /// - Parameter kinds: kinds from the standard catalog to add to the
    ///   fixture's own.
    init(
        policy: MCPPolicy = .standard, kinds: [AnyEventKind] = [],
        permissionStatus: @escaping EventDescriptor.Permission.StatusReader = { $0.status }
    ) throws {
        currentPolicy = Mutex(policy)
        TickEvent.started.store(0, ordering: .relaxed)
        fixture = try MCPFixture()
        hub = EventHub(catalog: EventCatalog([AnyEventKind(TickEvent.self), AnyEventKind(SecretEvent.self)] + kinds))
        let paths = fixture.paths
        let engine = fixture.daemon.engine
        let configuration = ConfigurationStatus(
            file: "", source: .defaults, effective: .init(), problem: nil, appliedAt: 0)
        // Read through `self` once it exists; until then nothing can ask.
        let holder = PolicyHolder()
        let service = MCPService(
            hub: hub, engine: engine, dryRunner: fixture.daemon.dryRunner, sampleDatabase: paths.sampleDatabase,
            policy: { holder.read() },
            configuration: { configuration },
            status: {
                DaemonStatus(
                    version: "test", pid: getpid(), startedAt: 0, executablePath: "", rulesDirectory: "",
                    handlerHost: await engine.hostStatus(), sources: [], rules: [], configuration: configuration)
            },
            permissionStatus: permissionStatus)
        let inbox = inbox
        endpoint = MCPEndpoint(service: service) { data in
            inbox.receive(try JSONDecoder().decode(JSONValue.self, from: data))
        }
        holder.peer = self
    }

    static func meta(version: String) -> JSONValue {
        [
            "io.modelcontextprotocol/protocolVersion": .string(version),
            "io.modelcontextprotocol/clientCapabilities": [:],
            "io.modelcontextprotocol/clientInfo": ["name": "test", "version": "1"],
        ]
    }

    /// Sends a request and returns its id.
    @discardableResult
    func send(_ method: String, _ params: JSONValue = [:], modern: Bool = false, version: String = "2026-07-28")
        throws -> Int
    {
        let id = ids.add(1, ordering: .relaxed).newValue
        var params = params
        if modern, case .object(var fields) = params {
            fields["_meta"] = Self.meta(version: version)
            params = .object(fields)
        }
        try deliver(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
        return id
    }

    func notify(_ method: String, _ params: JSONValue = [:]) throws {
        try deliver(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }

    func request(_ method: String, _ params: JSONValue = [:], modern: Bool = false, version: String = "2026-07-28")
        async throws -> JSONValue
    {
        try await response(to: send(method, params, modern: modern, version: version))
    }

    func response(to id: Int) async throws -> JSONValue {
        try await message { $0["id"] == .number(Double(id)) && $0["method"] == nil }
    }

    func message(where predicate: @escaping @Sendable (JSONValue) -> Bool) async throws -> JSONValue {
        try await inbox.first(where: predicate)
    }

    /// A resource's JSON content.
    func read(_ uri: String) async throws -> JSONValue {
        let response = try await request("resources/read", ["uri": .string(uri)], modern: true)
        let text = try #require(response["result"]?["contents"]?.arrayValue?.first?["text"]?.stringValue, "\(response)")
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// An `events_sample` call's result.
    func call(_ arguments: JSONValue) async throws -> JSONValue {
        let response = try await request(
            "tools/call", ["name": "events_sample", "arguments": arguments], modern: true)
        return try #require(response["result"], "\(response)")
    }

    private func deliver(_ message: JSONValue) throws {
        try endpoint.deliver(JSONEncoder().encode(message))
    }
}

/// Lets the service read the peer's policy, which the peer can change
/// between requests.
final class PolicyHolder: @unchecked Sendable {
    weak var peer: Peer?
    func read() -> MCPPolicy { peer?.policy ?? .standard }
}

/// Messages from the server, each taken by the first waiter that wants it.
final class Inbox: Sendable {
    private struct Waiter {
        let predicate: @Sendable (JSONValue) -> Bool
        let continuation: CheckedContinuation<JSONValue, any Error>
    }

    private struct State {
        var messages: [JSONValue] = []
        var waiters: [UUID: Waiter] = [:]
    }

    private let state = Mutex(State())

    struct Timeout: Error {}

    func receive(_ message: JSONValue) {
        let waiter = state.withLock { state -> Waiter? in
            guard let (key, waiter) = state.waiters.first(where: { $0.value.predicate(message) }) else {
                state.messages.append(message)
                return nil
            }
            state.waiters[key] = nil
            return waiter
        }
        waiter?.continuation.resume(returning: message)
    }

    func first(where predicate: @escaping @Sendable (JSONValue) -> Bool, timeout: Duration = .seconds(10))
        async throws -> JSONValue
    {
        let key = UUID()
        let timer = Task { [weak self] in
            try await Task.sleep(for: timeout)
            let waiter = self?.state.withLock { $0.waiters.removeValue(forKey: key) }
            waiter?.continuation.resume(throwing: Timeout())
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            let found = state.withLock { state -> JSONValue? in
                if let index = state.messages.firstIndex(where: predicate) {
                    return state.messages.remove(at: index)
                }
                state.waiters[key] = Waiter(predicate: predicate, continuation: continuation)
                return nil
            }
            if let found { continuation.resume(returning: found) }
        }
    }
}

/// What MCP may sample by default (docs/cli.md, "MCP"; mcp.md, "Harm model").
struct MCPDefaultPolicyTests {
    /// Kinds a rule must name to observe that MCP offers by default, and
    /// why: what each carries is no text a program chose to put there, or
    /// no more than an open kind already carries. Every other named kind
    /// is denied by default, so a new one is decided here rather than left
    /// open.
    static let openNamed: [String: String] = [
        "camera.inUse": "device names, as the open audio.devices carries",
        "audio.inUse": "device names, as the open audio.devices carries",
        "pasteboard.changed": "a change counter; never the contents",
        "session.logins": "user names, terminals and a remote login's host, from utmpx",
    ]

    @Test func everyNamedKindIsDeniedOrOpenForAReason() {
        let named = EventCatalog.standard.kinds.map(\.descriptor).filter { $0.observation == .named }
        #expect(!named.isEmpty)
        let open = named.filter { !MeerkatConfiguration.MCP.Events.deniedByDefault($0) }.map(\.name)
        #expect(Set(open) == Set(Self.openNamed.keys), "decide each in openNamed or rawKinds")
    }

    /// A power assertion's name is free text the asserting program chose.
    @Test func powerAssertionsAreDeniedByDefault() throws {
        let kind = try #require(EventCatalog.standard.kind(named: "power.assertions"))
        #expect(!MCPPolicy.standard.allows(kind))
    }
}

struct RuleLogBoundTests {
    /// A rule's log read over MCP stays within the output limit: the newest
    /// entries are kept, and the older ones left out are counted.
    @Test func ruleLogsKeepTheNewestWithinTheOutputLimit() throws {
        let entries = (0..<10).map {
            RuleLogEntry(
                rule: "a.ts#r", time: Double(10 - $0), level: .info, message: String(repeating: "x", count: 16_384))
        }
        let log = MCPService.RuleLog(entries, outputBytes: 50_000)
        #expect(log.entries == Array(entries.prefix(3)))
        #expect(log.omitted == 7)
        #expect(try MCPService.encode(log).utf8.count <= 50_000)
        #expect(MCPService.RuleLog(entries, outputBytes: 1 << 20) == MCPService.RuleLog(entries, outputBytes: .max))
        #expect(MCPService.RuleLog(entries, outputBytes: 1 << 20).omitted == 0)
    }

    /// Any other reply over the limit is cut to it, saying so: a rules report
    /// of long errors, or diagnostics, whatever escaping does to its size.
    @Test(arguments: [String(repeating: "x", count: 100_000), String(repeating: "\u{1}\"", count: 50_000), "é😀"])
    func repliesOverTheLimitAreCutToIt(text: String) throws {
        let limit = 1000
        let reply = MCPService.bounded(text, outputBytes: limit)
        guard text.utf8.count > limit else {
            #expect(reply == text)
            return
        }
        #expect(reply.utf8.count <= limit)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8))
        #expect(decoded["truncated"] == true)
        #expect(decoded["bytes"] == .number(Double(text.utf8.count)))
        let kept = try #require(decoded["text"]?.stringValue)
        #expect(!kept.isEmpty && text.hasPrefix(kept))
    }
}

extension SystemSample {
    /// A sample with `cpu` as its machine-wide CPU, taken `minute` minutes
    /// past noon.
    static func test(cpu: Double, minute: Int) -> SystemSample {
        SystemSample(
            timestamp: String(format: "2026-11-05T12:%02d:00Z", minute), host: "test-host", cpuCount: 10,
            windowSeconds: 5,
            cpuUsagePercent: cpu, load1: 1, load5: 1, load15: 1,
            memory: MemorySample(
                pageSize: 16_384, freeMB: 100, activeMB: 200, inactiveMB: 50, wiredMB: 25, compressedMB: 10,
                swapUsedMB: 0, swapTotalMB: 1_024),
            processes: [], churn: nil)
    }
}
