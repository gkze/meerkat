//! End-to-end tests of a real host: Deno workers, the watchdog and the
//! protocol, driven the way the daemon drives them.

use std::fmt::Write;
use std::sync::Mutex;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::Duration;

use serde_json::{Value, json};

use crate::host::{Delivery, Host};
use crate::protocol::{
    DaemonToHost, EffectOutcome, EntryResult, FaultKind, FilePermissions, HandlerError, HostLogLevel, HostModule,
    HostToDaemon,
};

enum Event {
    Message(HostToDaemon),
    Terminated(String),
}

struct Collect(Sender<Event>);

impl Delivery for Collect {
    fn message(&mut self, message: HostToDaemon) {
        let _ = self.0.send(Event::Message(message));
    }

    fn terminated(&mut self, reason: &str) {
        let _ = self.0.send(Event::Terminated(reason.to_owned()));
    }
}

struct Harness {
    host: Host,
    events: Receiver<Event>,
}

/// The part of the daemon's effect table these tests use: the shapes
/// `runtime.js` turns into context methods (the daemon sends the whole
/// catalog, `EffectCatalog.runtimeTable`).
const EFFECTS: &str = r#"[
  {"kind":"state.get","method":["state","get"],"arguments":["key"],"result":"optional"},
  {"kind":"state.set","method":["state","set"],"arguments":["key","value"],"result":"none"},
  {"kind":"state.delete","method":["state","delete"],"arguments":["key"],"result":"none"},
  {"kind":"notify.withdraw","method":["notify","withdraw"],"arguments":["id"],"result":"none"},
  {"kind":"notify","method":["notify"],"arguments":null,"result":"none"},
  {"kind":"exec","method":["exec"],"arguments":null,"result":"value"}
]"#;

/// A `log` message's fields.
#[derive(Debug, PartialEq)]
struct Log {
    rule: Option<String>,
    level: HostLogLevel,
    message: String,
}

const WAIT: Duration = Duration::from_secs(20);

const OUT_OF_MEMORY: FaultKind = FaultKind::OutOfMemory;
const HEAP_EXHAUSTED: &str = "passed its JavaScript heap limit of 256 MB";

impl Harness {
    fn start() -> Harness {
        let (sender, events) = channel();
        let harness = Harness { host: Host::start(Collect(sender)), events };
        harness.next("ready", |message| matches!(message, HostToDaemon::Ready).then_some(()));
        harness
    }

    fn send(&self, message: DaemonToHost) {
        self.host.receive(message);
    }

    /// Loads `modules` (id, TypeScript-free JavaScript) with every top-level
    /// id as an entry, and returns the `loaded` results.
    fn load(&self, modules: &[(&str, &str)], deadline: f64) -> Vec<EntryResult> {
        self.load_logged(modules, deadline).0
    }

    /// `load`, plus the log messages sent while the files loaded.
    fn load_logged(&self, modules: &[(&str, &str)], deadline: f64) -> (Vec<EntryResult>, Vec<Log>) {
        let entries = modules.iter().map(|(id, _)| *id).filter(|id| !id.contains('/')).map(str::to_owned).collect();
        let modules = modules.iter().map(|(id, code)| HostModule { id: (*id).into(), code: (*code).into() }).collect();
        self.send(DaemonToHost::Load {
            modules,
            entries,
            rejected: [("broken".into(), "broken.ts has type errors".into())].into(),
            entry_deadline_seconds: deadline,
            effects: EFFECTS.into(),
        });
        let mut logs = Vec::new();
        loop {
            match self.events.recv_timeout(WAIT).unwrap_or_else(|_| panic!("no loaded within {WAIT:?}")) {
                Event::Message(HostToDaemon::Loaded { results }) => return (results, logs),
                Event::Message(HostToDaemon::Log { rule, level, message }) => logs.push(Log { rule, level, message }),
                Event::Message(_) => {}
                Event::Terminated(reason) => panic!("terminated ({reason}) while waiting for loaded"),
            }
        }
    }

    fn invoke(&self, invocation: u64, rule: &str, payload: Value, timeout: f64) {
        let event = json!({ "kind": "timer", "sequence": 1, "time": 0, "origin": "system", "replayed": false, "payload": payload });
        self.send(DaemonToHost::Invoke {
            invocation,
            rule: rule.into(),
            event: event.to_string(),
            timeout_seconds: timeout,
        });
    }

    fn permit(&self, entry: &str, permissions: FilePermissions) {
        self.send(DaemonToHost::Permit { entry: entry.into(), permissions });
    }

    /// The first message `pick` accepts, skipping others; panics on
    /// termination.
    fn next<T>(&self, what: &str, pick: impl Fn(HostToDaemon) -> Option<T>) -> T {
        loop {
            match self.events.recv_timeout(WAIT).unwrap_or_else(|_| panic!("no {what} within {WAIT:?}")) {
                Event::Message(message) => {
                    if let Some(found) = pick(message) {
                        return found;
                    }
                }
                Event::Terminated(reason) => panic!("terminated ({reason}) while waiting for {what}"),
            }
        }
    }

    fn next_log(&self) -> Log {
        self.next("log", |message| match message {
            HostToDaemon::Log { rule, level, message } => Some(Log { rule, level, message }),
            _ => None,
        })
    }

    /// Every message until `invocation` is done, and the error it ended with.
    fn until_done(&self, invocation: u64) -> (Vec<HostToDaemon>, Option<HandlerError>) {
        let mut seen = Vec::new();
        loop {
            match self.events.recv_timeout(WAIT).expect("an answer") {
                Event::Message(HostToDaemon::InvocationDone { invocation: done, error }) if done == invocation => {
                    return (seen, error);
                }
                Event::Message(message) => seen.push(message),
                Event::Terminated(reason) => panic!("terminated: {reason}"),
            }
        }
    }

    /// Asserts `invocation` ends without an error and returns its log lines.
    fn logs_until_done(&self, invocation: u64) -> Vec<String> {
        let (seen, error) = self.until_done(invocation);
        assert_eq!(error, None, "{seen:?}");
        logs(&seen)
    }

    /// The error `invocation` ended with; panics when it succeeded.
    fn error_until_done(&self, invocation: u64) -> String {
        self.until_done(invocation).1.expect("an error").message
    }

    fn terminated(&self) -> (Vec<HostToDaemon>, String) {
        let mut seen = Vec::new();
        loop {
            match self.events.recv_timeout(WAIT).expect("termination") {
                Event::Message(message) => seen.push(message),
                Event::Terminated(reason) => return (seen, reason),
            }
        }
    }
}

fn logs(messages: &[HostToDaemon]) -> Vec<String> {
    messages
        .iter()
        .filter_map(|message| match message {
            HostToDaemon::Log { message, .. } => Some(message.clone()),
            _ => None,
        })
        .collect()
}

/// The one `fault` among `messages`: file, rule, invocation, kind and
/// reason.
fn fault(messages: &[HostToDaemon]) -> (&str, Option<&str>, Option<u64>, FaultKind, &str) {
    let faults: Vec<_> = messages
        .iter()
        .filter_map(|message| match message {
            HostToDaemon::Fault { file, rule, invocation, kind, reason } => {
                Some((file.as_str(), rule.as_deref(), *invocation, *kind, reason.as_str()))
            }
            _ => None,
        })
        .collect();
    let [fault] = faults.as_slice() else { panic!("not one fault: {messages:?}") };
    *fault
}

fn result<'a>(results: &'a [EntryResult], entry: &str) -> &'a EntryResult {
    results.iter().find(|result| result.entry == entry).unwrap_or_else(|| panic!("no result for {entry}"))
}

/// The entry's rule definitions, parsed.
fn rules(result: &EntryResult) -> Value {
    result.rules.iter().map(|rule| serde_json::from_str::<Value>(rule).expect("definitions are JSON")).collect()
}

/// The entry's error message, or "" when it loaded.
fn load_error(results: &[EntryResult], entry: &str) -> String {
    result(results, entry).error.as_ref().map(|error| error.message.clone()).unwrap_or_default()
}

fn granting(read: &[&str], write: &[&str]) -> FilePermissions {
    let strings = |paths: &[&str]| paths.iter().map(|path| (*path).to_owned()).collect();
    FilePermissions { read: strings(read), write: strings(write), ..FilePermissions::default() }
}

/// `path`'s name on the data volume, which `realpath` keeps: the same
/// folder, reached under the volume's mount point rather than through its
/// firmlink (`/private`, holding the temporary folder).
fn on_data_volume(path: &std::path::Path) -> std::path::PathBuf {
    std::path::Path::new("/System/Volumes/Data").join(path.strip_prefix("/").unwrap())
}

fn scratch(name: &str) -> std::path::PathBuf {
    let directory = std::env::temp_dir().join(format!("meerkat-runtime-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&directory);
    std::fs::create_dir_all(&directory).unwrap();
    directory.canonicalize().unwrap()
}

/// (`#` separates a rule's file from its name, so the daemon loads no entry
/// whose name holds one: `RuleCompiler`.)
#[test]
fn an_entry_id_with_url_characters_loads() {
    let harness = Harness::start();
    let code = r#"
        import { rule } from "meerkat";
        export const x = rule({ name: "x", on: "timer", params: { every: 1 }, handle() {} });
    "#;
    let results = harness.load(&[("a b?c%d", code)], 5.0);
    assert_eq!(results[0].error, None, "{results:?}");
}

/// The table's order does not matter: `notify.withdraw` comes before `notify`
/// in `EFFECTS`.
#[test]
fn a_method_keeps_the_members_placed_before_it() {
    let harness = Harness::start();
    let code = r#"
        import { rule } from "meerkat";
        export const x = rule({ name: "x", on: "timer", params: { every: 1 }, handle(event, ctx) {
          ctx.warn(typeof ctx.notify, typeof ctx.notify.withdraw);
        } });
    "#;
    harness.load(&[("tree", code)], 5.0);
    harness.invoke(1, "tree.ts#x", json!({}), 5.0);
    assert_eq!(harness.next_log().message, "function function");
}

#[test]
fn loads_invokes_and_round_trips_effects() {
    let harness = Harness::start();
    let results = harness.load(
        &[
            ("lib/twice", "export const twice = (n) => n * 2;\n"),
            (
                "count",
                r#"
            import { rule } from "meerkat";
            import { twice } from "./lib/twice";
            export const count = rule({ name: "count", on: "timer", params: { every: 1 }, async handle(event, ctx, meta) {
              console.log("value", twice(event.count), meta.kind);
              const stored = await ctx.state.get("n");
              ctx.warn("stored", stored);
            } });
        "#,
            ),
        ],
        5.0,
    );
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].entry, "count");
    assert_eq!(rules(&results[0]), json!([{ "name": "count", "on": "timer", "params": { "every": 1 } }]));
    assert_eq!(results[0].error, None, "{results:?}");

    harness.invoke(1, "count.ts#count", json!({ "count": 21 }), 5.0);
    let started = harness.next("started", |message| match message {
        HostToDaemon::Started { invocation } => Some(invocation),
        _ => None,
    });
    assert_eq!(started, 1);
    assert_eq!(
        harness.next_log(),
        Log { rule: Some("count.ts#count".into()), level: HostLogLevel::Info, message: "value 42 timer".into() }
    );
    let (call, rule, request) = harness.next("effect", |message| match message {
        HostToDaemon::Effect { call, rule, request, .. } => Some((call, rule, request)),
        _ => None,
    });
    assert_eq!(serde_json::from_str::<Value>(&request).unwrap(), json!({ "kind": "state.get", "key": "n" }));
    assert_eq!(rule, "count.ts#count");
    let value = json!({ "found": true, "value": 7 }).to_string();
    harness.send(DaemonToHost::EffectResult { call, result: EffectOutcome::Success { value } });
    let seen = harness.logs_until_done(1);
    assert!(seen.contains(&"stored 7".to_owned()), "{seen:?}");
}

#[test]
fn an_entry_runs_the_rules_it_exports() {
    let harness = Harness::start();
    let (results, logs) = harness.load_logged(
        &[
            (
                "lib/marks",
                r#"
            import { rule } from "meerkat";
            export const first = rule({ name: "first", on: "timer", handle() {} });
            export const unused = rule({ name: "unused", on: "timer", handle() {} });
        "#,
            ),
            (
                "index",
                r#"
            import { rule } from "meerkat";
            export { first, first as alias } from "./lib/marks";
            export const grouped = [rule({ name: "second", on: "timer", handle() {} })];
            export const helper = () => 1;
            export const strings = ["not", "rules"];
        "#,
            ),
            (
                "old",
                r#"
            import { rule } from "meerkat";
            rule({ name: "a", on: "timer", handle() {} });
        "#,
            ),
            (
                "twice",
                r#"
            import { rule } from "meerkat";
            export const one = rule({ name: "same", on: "timer", handle() {} });
            export const two = rule({ name: "same", on: "timer", handle() {} });
        "#,
            ),
            (
                "mixed",
                r#"
            import { rule } from "meerkat";
            export const all = [rule({ name: "r", on: "timer", handle() {} }), "oops"];
        "#,
            ),
        ],
        5.0,
    );
    let index = result(&results, "index");
    assert_eq!(index.error, None, "{index:?}");
    // In creation order; `unused` was created by the imported module and not re-exported.
    assert_eq!(rules(index), json!([{ "name": "first", "on": "timer" }, { "name": "second", "on": "timer" }]));
    let message = |entry: &str| load_error(&results, entry);
    assert!(message("old").contains("old.ts creates rules (a) but exports none"), "{results:?}");
    assert!(message("twice").contains("rule \"same\" is defined twice in twice.ts"), "{results:?}");
    assert!(message("mixed").contains("export \"all\" mixes rules with other values: item 1"), "{results:?}");

    let warning = Log {
        rule: Some("index.ts".into()),
        level: HostLogLevel::Warn,
        message: "rules created but not exported by index.ts, so not running: unused".into(),
    };
    assert!(logs.contains(&warning), "{logs:?}");
    harness.invoke(1, "index.ts#second", json!({}), 5.0);
    harness.logs_until_done(1);
    harness.invoke(2, "index.ts#unused", json!({}), 5.0);
    assert_eq!(harness.error_until_done(2), "no rule index.ts#unused is loaded");
}

#[test]
fn a_default_export_and_nested_arrays_hold_rules() {
    let harness = Harness::start();
    let results = harness.load(
        &[
            (
                "single",
                r#"
            import { rule } from "meerkat";
            export default rule({ name: "only", on: "timer", handle() {} });
        "#,
            ),
            (
                "list",
                r#"
            import { rule } from "meerkat";
            export default [
              rule({ name: "a", on: "timer", handle() {} }),
              rule({ name: "b", on: "timer", handle() {} }),
            ];
        "#,
            ),
            (
                "nested",
                r#"
            import { rule } from "meerkat";
            const audio = [rule({ name: "a", on: "timer", handle() {} })];
            const power = [[rule({ name: "b", on: "timer", handle() {} })], []];
            const looped = [audio];
            looped.push(looped);
            export default [audio, power, looped];
            export const table = [[1, 2], [3]];
        "#,
            ),
            (
                "deep-mixed",
                r#"
            import { rule } from "meerkat";
            export default [[rule({ name: "r", on: "timer", handle() {} })], [1, ["oops"]]];
        "#,
            ),
        ],
        5.0,
    );
    let names = |entry: &str| {
        let loaded = result(&results, entry);
        assert_eq!(loaded.error, None, "{loaded:?}");
        rules(loaded).as_array().expect("an array").iter().map(|rule| rule["name"].clone()).collect::<Vec<_>>()
    };
    assert_eq!(names("single"), [json!("only")]);
    assert_eq!(names("list"), [json!("a"), json!("b")]);
    assert_eq!(names("nested"), [json!("a"), json!("b")]);
    let message = load_error(&results, "deep-mixed");
    assert!(message.contains("export \"default\" mixes rules with other values: item 1.0"), "{results:?}");

    harness.invoke(1, "single.ts#only", json!({}), 5.0);
    harness.logs_until_done(1);
    harness.invoke(2, "nested.ts#b", json!({}), 5.0);
    harness.logs_until_done(2);
}

#[test]
fn a_handler_error_and_an_unknown_rule_are_reported() {
    let harness = Harness::start();
    harness.load(
        &[(
            "fail",
            r#"
        import { rule } from "meerkat";
        export const fail = rule({ name: "fail", on: "timer", handle() { throw new TypeError("nope"); } });
        export const hashed = rule({ name: "y.ts#c", on: "timer", handle() {} });
    "#,
        )],
        5.0,
    );
    harness.invoke(1, "fail.ts#fail", json!({}), 5.0);
    assert_eq!(harness.error_until_done(1), "TypeError: nope");
    harness.invoke(2, "fail.ts#missing", json!({}), 5.0);
    assert_eq!(harness.error_until_done(2), "no rule fail.ts#missing is loaded");
    // A name holding `#` would make an id another file's rule could have
    // (`fail.ts#y.ts` and `c`); the daemon fails it, and it is not routed.
    harness.invoke(3, "fail.ts#y.ts#c", json!({}), 5.0);
    assert_eq!(harness.error_until_done(3), "no rule fail.ts#y.ts#c is loaded");
}

#[test]
fn imports_are_limited_to_the_rules() {
    let harness = Harness::start();
    let results = harness.load(
        &[
            ("net", "import \"https://example.com/x.js\";\n"),
            ("uses", "import \"./broken\";\n"),
            ("late", "import { rule } from \"meerkat\";\nsetTimeout(() => {});\n"),
            ("node", "import { join } from \"node:path\";\njoin(\"a\", \"b\");\n"),
        ],
        5.0,
    );
    let error = |entry: &str| load_error(&results, entry);
    assert!(error("net").contains("rules may import \"meerkat\" and relative paths only"), "{results:?}");
    assert!(error("uses").contains("cannot load ./broken: broken.ts has type errors"), "{results:?}");
    assert_eq!(error("late"), "");
    // Deno's own modules are the runtime's, like `Deno`: they resolve
    // before the loader is asked (loader.rs).
    assert_eq!(error("node"), "");
}

#[test]
fn deno_apis_follow_the_files_permit() {
    let directory = scratch("permit");
    let allowed = directory.join("allowed");
    std::fs::create_dir_all(&allowed).unwrap();
    let harness = Harness::start();
    let code = format!(
        r#"
        import {{ rule }} from "meerkat";
        const attempt = async (what, run) => {{
          try {{ await run(); console.log(what, "ok"); }} catch (e) {{ console.log(what, e.name); }}
        }};
        export const write = rule({{ name: "write", on: "timer", async handle() {{
          await attempt("inside", () => Deno.writeTextFile("{inside}", ""));
          await attempt("outside", () => Deno.writeTextFile("{outside}", ""));
          await attempt("read", () => Deno.stat("{allowed}"));
          await attempt("fetch", () => fetch("https://example.com"));
          await attempt("env", () => Deno.env.get("HOME"));
          await attempt("run", () => new Deno.Command("/usr/bin/true").output());
        }} }});
    "#,
        inside = allowed.join(".metadata_never_index").display(),
        outside = directory.join("outside").display(),
        allowed = allowed.display()
    );
    harness.load(&[("perm", &code)], 5.0);

    // Before any permit, nothing is granted.
    harness.invoke(1, "perm.ts#write", json!({}), 10.0);
    let before = harness.logs_until_done(1);
    assert_eq!(
        before,
        [
            "inside NotCapable",
            "outside NotCapable",
            "read NotCapable",
            "fetch NotCapable",
            "env NotCapable",
            "run NotCapable"
        ]
    );

    // An empty permit still grants nothing (in Deno's own options, an empty
    // list would mean everything).
    harness.permit("perm", granting(&[], &[]));
    harness.invoke(2, "perm.ts#write", json!({}), 10.0);
    assert_eq!(harness.logs_until_done(2), before);

    harness.permit("perm", granting(&[], &[allowed.to_str().unwrap()]));
    harness.invoke(3, "perm.ts#write", json!({}), 10.0);
    assert_eq!(
        harness.logs_until_done(3),
        ["inside ok", "outside NotCapable", "read NotCapable", "fetch NotCapable", "env NotCapable", "run NotCapable"]
    );
    assert!(allowed.join(".metadata_never_index").exists());
    assert!(!directory.join("outside").exists());

    // A deny inside the grant wins.
    let mut deny = granting(&[allowed.to_str().unwrap()], &[allowed.to_str().unwrap()]);
    deny.deny_write = vec![allowed.join(".metadata_never_index").display().to_string()];
    harness.permit("perm", deny);
    harness.invoke(4, "perm.ts#write", json!({}), 10.0);
    assert_eq!(harness.logs_until_done(4)[..3], ["inside NotCapable", "outside NotCapable", "read ok"]);
}

#[test]
fn rule_code_cannot_act_on_the_whole_process() {
    let directory = scratch("process");
    let before = std::env::current_dir().unwrap();
    let harness = Harness::start();
    harness.load(
        &[(
            "proc",
            &format!(
                r#"
        import {{ rule }} from "meerkat";
        import v8 from "node:v8";
        export const p = rule({{ name: "p", on: "timer", async handle() {{
          for (const [what, run] of [
            ["exit", () => Deno.exit(3)],
            ["chdir", () => Deno.chdir("{directory}")],
            ["signal", () => Deno.addSignalListener("SIGTERM", () => {{}})],
            ["worker", () => new Worker("data:,", {{ type: "module" }})],
            ["abort", () => process.abort()],
            ["kill", () => process.kill(process.pid, "SIGKILL")],
            ["title", () => {{ process.title = "renamed"; }}],
            ["flags", () => v8.setFlagsFromString("--abort-on-uncaught-exception")],
            ["heap", () => v8.setHeapSnapshotNearHeapLimit(1)],
          ]) {{
            try {{ run(); console.log(what, "returned"); }} catch (e) {{ console.log(what, "threw"); }}
          }}
        }} }});
    "#,
                directory = directory.display()
            ),
        )],
        5.0,
    );
    harness.permit("proc", granting(&[directory.to_str().unwrap()], &[]));
    harness.invoke(1, "proc.ts#p", json!({}), 10.0);
    let seen = harness.logs_until_done(1);
    assert_eq!(seen.len(), 9, "{seen:?}");
    assert!(seen.iter().all(|line| line.ends_with("threw")), "{seen:?}");
    assert_eq!(std::env::current_dir().unwrap(), before);
}

/// An API Deno keeps behind a flag ends the process when the flag is off,
/// before any permission check and past any `catch`. Here it carries on to
/// that check.
#[test]
fn unstable_apis_do_not_end_the_process() {
    let harness = Harness::start();
    harness.load(
        &[(
            "unstable",
            r#"
        import { rule } from "meerkat";
        export const u = rule({ name: "u", on: "timer", async handle() {
          for (const [what, run] of [
            ["reusePort", () => Deno.listen({ port: 1, reusePort: true })],
            ["connectVsock", () => Deno.connect({ transport: "vsock", cid: 1, port: 1 })],
            ["listenVsock", () => Deno.listen({ transport: "vsock", cid: 1, port: 1 })],
          ]) {
            try { await run(); console.log(what, "returned"); } catch (e) { console.log(what, e.name); }
          }
        } });
        export const after = rule({ name: "after", on: "timer", handle() {} });
    "#,
        )],
        5.0,
    );
    harness.invoke(1, "unstable.ts#u", json!({}), 10.0);
    let seen = harness.logs_until_done(1);
    assert_eq!(seen.len(), 3, "{seen:?}");
    assert!(seen.iter().all(|line| line.ends_with("NotCapable")), "{seen:?}");
    harness.invoke(2, "unstable.ts#after", json!({}), 5.0);
    harness.until_done(2);
}

#[test]
fn a_pending_handler_times_out_without_stopping_the_host() {
    let harness = Harness::start();
    harness.load(
        &[(
            "slow",
            r#"
        import { rule } from "meerkat";
        export const wait = rule({ name: "wait", on: "timer", handle() { return new Promise(() => {}); } });
        export const quick = rule({ name: "quick", on: "timer", handle() {} });
    "#,
        )],
        5.0,
    );
    harness.invoke(1, "slow.ts#wait", json!({}), 0.3);
    let timed_out = harness.next("invocationTimedOut", |message| match message {
        HostToDaemon::InvocationTimedOut { invocation } => Some(invocation),
        _ => None,
    });
    assert_eq!(timed_out, 1);
    harness.invoke(2, "slow.ts#quick", json!({}), 5.0);
    harness.logs_until_done(2);
}

#[test]
fn a_handler_holding_the_thread_stops_the_host_and_is_named() {
    let harness = Harness::start();
    harness.load(
        &[(
            "spin",
            r#"
        import { rule } from "meerkat";
        export const spin = rule({ name: "spin", on: "timer", handle() { for (;;) {} } });
    "#,
        )],
        5.0,
    );
    harness.invoke(1, "spin.ts#spin", json!({}), 0.3);
    let (seen, reason) = harness.terminated();
    let (file, rule, invocation, kind, why) = fault(&seen);
    assert_eq!((file, rule, invocation, kind), ("spin.ts", Some("spin.ts#spin"), Some(1), FaultKind::Overran));
    assert!(why.starts_with("held the JavaScript thread for "), "{why}");
    assert_eq!(reason, format!("spin.ts#spin {why}"));
}

/// A file's timers that take most of its thread, each within its own
/// budget, end the host as one holding the thread would.
#[test]
fn a_file_busy_outside_its_handlers_stops_the_host_and_is_named() {
    let harness = Harness::start();
    harness.load(
        &[(
            "busy",
            r#"
        import { rule } from "meerkat";
        // A fresh timer after each callback, so each runs in a poll of its own.
        const tick = () => { const end = Date.now() + 800; while (Date.now() < end) {} setTimeout(tick, 100); };
        setTimeout(tick, 0);
        export const idle = rule({ name: "idle", on: "timer", handle() {} });
    "#,
        )],
        5.0,
    );
    let (seen, _) = harness.terminated();
    let (file, rule, invocation, kind, why) = fault(&seen);
    assert_eq!((file, rule, invocation, kind), ("busy.ts", None, None, FaultKind::Overran));
    assert!(why.starts_with("kept the JavaScript thread busy"), "{why}");
}

#[test]
fn a_file_that_does_not_finish_loading_fails_alone() {
    // The daemon's deadline, not a shorter one: each file's clock starts
    // when its worker is created, so `fine` spends part of it starting an
    // isolate, which a loaded machine can stretch past a short deadline.
    let harness = Harness::start();
    let results = harness.load(
        &[
            ("spin", "for (;;) {}\n"),
            ("hang", "await new Promise(() => {});\n"),
            ("fine", "import { rule } from \"meerkat\";\nexport const ok = rule({ name: \"ok\", on: \"timer\", handle() {} });\n"),
        ],
        5.0,
    );
    for entry in ["spin", "hang"] {
        assert_eq!(load_error(&results, entry), "top-level code did not finish within 5 s", "{entry}");
    }
    harness.invoke(1, "fine.ts#ok", json!({}), 5.0);
    harness.logs_until_done(1);
}

#[test]
fn errors_nothing_caught_are_logged_and_the_file_keeps_running() {
    let harness = Harness::start();
    harness.load(
        &[(
            "loose",
            r#"
        import { rule } from "meerkat";
        export const loose = rule({ name: "loose", on: "timer", handle() {
          Promise.reject(new Error("dropped"));
          setTimeout(() => { throw new Error("from a timer"); }, 0);
        } });
        export const after = rule({ name: "after", on: "timer", handle() {} });
    "#,
        )],
        5.0,
    );
    harness.invoke(1, "loose.ts#loose", json!({}), 5.0);
    harness.until_done(1);
    let mut seen = Vec::new();
    while seen.len() < 2 {
        seen.push(harness.next_log().message);
    }
    assert!(seen.iter().any(|line| line.starts_with("unhandled rejection: Error: dropped")), "{seen:?}");
    assert!(seen.iter().any(|line| line.starts_with("uncaught Error: from a timer")), "{seen:?}");
    harness.invoke(2, "loose.ts#after", json!({}), 5.0);
    harness.until_done(2);
}

#[test]
fn exhausting_the_heap_stops_the_host_not_the_process() {
    let harness = Harness::start();
    harness.load(
        &[(
            "hog",
            r#"
        import { rule } from "meerkat";
        export const hog = rule({ name: "hog", on: "timer", handle() {
          const keep = [];
          for (;;) keep.push(new Array(1 << 16).fill(keep.length));
        } });
    "#,
        )],
        5.0,
    );
    harness.invoke(1, "hog.ts#hog", json!({}), 60.0);
    let (seen, reason) = harness.terminated();
    // The heap is the file's: charged to it, naming the handler that made
    // the last allocation only as a clue.
    let while_hog = format!("{HEAP_EXHAUSTED} (while hog.ts#hog ran)");
    assert_eq!(fault(&seen), ("hog.ts", None, None, OUT_OF_MEMORY, while_hog.as_str()));
    assert_eq!(reason, format!("hog.ts {while_hog}"));
}

/// The rule that runs out of heap need not be the one holding the memory:
/// here `keep` holds most of it and `grow` makes the last allocation.
#[test]
fn exhausting_the_heap_is_charged_to_the_file_not_the_last_allocator() {
    let harness = Harness::start();
    harness.load(
        &[(
            "shared",
            r#"
        import { rule } from "meerkat";
        const kept = [];
        export const keep = rule({ name: "keep", on: "timer", handle() {
          for (let i = 0; i < 1000; i++) kept.push(new Array(1 << 14).fill(i));
        } });
        export const grow = rule({ name: "grow", on: "timer", handle() {
          for (;;) kept.push(new Array(1 << 16).fill(0));
        } });
    "#,
        )],
        5.0,
    );
    harness.invoke(1, "shared.ts#keep", json!({}), 60.0);
    harness.until_done(1);
    harness.invoke(2, "shared.ts#grow", json!({}), 60.0);
    let (seen, _) = harness.terminated();
    let (file, rule, invocation, kind, _) = fault(&seen);
    assert_eq!((file, rule, invocation, kind), ("shared.ts", None, None, OUT_OF_MEMORY));
}

/// A timer that exhausts the heap is charged to its file.
#[test]
fn exhausting_the_heap_outside_a_handler_is_charged_to_the_file() {
    let harness = Harness::start();
    harness.load(
        &[(
            "leak",
            r#"
        import { rule } from "meerkat";
        const keep = [];
        setTimeout(() => { for (;;) keep.push(new Array(1 << 16).fill(keep.length)); }, 0);
        export const idle = rule({ name: "idle", on: "timer", handle() {} });
    "#,
        )],
        5.0,
    );
    let (seen, _) = harness.terminated();
    assert_eq!(fault(&seen), ("leak.ts", None, None, OUT_OF_MEMORY, HEAP_EXHAUSTED));
}

/// One object past the limit, which no amount of collecting can make room
/// for.
#[test]
fn one_allocation_past_the_heap_limit_stops_the_host_not_the_process() {
    let harness = Harness::start();
    harness.load(
        &[(
            "large",
            r#"
        import { rule } from "meerkat";
        export const large = rule({ name: "large", on: "timer", handle() {
          new TextEncoder().encode("x".repeat(400_000_000) + "y");
        } });
    "#,
        )],
        5.0,
    );
    harness.invoke(1, "large.ts#large", json!({}), 60.0);
    let (seen, _) = harness.terminated();
    let while_large = format!("{HEAP_EXHAUSTED} (while large.ts#large ran)");
    assert_eq!(fault(&seen), ("large.ts", None, None, OUT_OF_MEMORY, while_large.as_str()));
}

/// Rule code runs before any handler, and may change the prototypes the
/// runtime's own objects would otherwise inherit from.
#[test]
fn changed_prototypes_do_not_reach_the_context() {
    let harness = Harness::start();
    harness.load(
        &[(
            "proto",
            r#"
        import { rule } from "meerkat";
        Object.prototype.state = 1;
        Object.defineProperty(Object.prototype, "key", { set() { throw new Error("key"); }, configurable: true });
        Object.defineProperty(Function.prototype, "withdraw", { set() { throw new Error("withdraw"); }, configurable: true });
        export const p = rule({ name: "p", on: "timer", async handle(event, ctx) {
          ctx.warn(typeof ctx.state.get, typeof ctx.notify.withdraw);
          ctx.warn(await ctx.state.get("k"));
        } });
    "#,
        )],
        5.0,
    );
    harness.invoke(1, "proto.ts#p", json!({}), 5.0);
    assert_eq!(harness.next_log().message, "function function");
    let request = harness.next("effect", |message| match message {
        HostToDaemon::Effect { call, request, .. } => Some((call, request)),
        _ => None,
    });
    assert_eq!(serde_json::from_str::<Value>(&request.1).unwrap(), json!({ "kind": "state.get", "key": "k" }));
    let value = json!({ "found": true, "value": "kept" }).to_string();
    harness.send(DaemonToHost::EffectResult { call: request.0, result: EffectOutcome::Success { value } });
    assert_eq!(harness.logs_until_done(1), ["kept"]);
}

/// A failure before the handler runs (here in Deno's console, which the
/// context's logger is) is that invocation's failure, and the file's
/// dispatcher keeps serving.
#[test]
fn a_failure_before_the_handler_ends_only_that_invocation() {
    let harness = Harness::start();
    harness.load(
        &[(
            "hooked",
            r#"
        import { rule } from "meerkat";
        Object.defineProperty(Object.prototype, "log", { set() { throw new Error("hooked"); }, configurable: true });
        export const a = rule({ name: "a", on: "timer", handle() {} });
    "#,
        )],
        5.0,
    );
    for invocation in [1, 2] {
        harness.invoke(invocation, "hooked.ts#a", json!({}), 5.0);
        assert!(harness.error_until_done(invocation).contains("hooked"));
    }
}

/// What one file reports is bounded per file: definitions too large for a
/// message fail that file alone, and a long error is cut.
#[test]
fn oversized_output_fails_or_is_cut_for_its_file_alone() {
    let harness = Harness::start();
    let results = harness.load(
        &[
            (
                "huge",
                r#"
        import { rule } from "meerkat";
        export const h = rule({ name: "h", on: "timer", note: "x".repeat(5 << 20), handle() {} });
    "#,
            ),
            (
                "loud",
                r#"
        import { rule } from "meerkat";
        export const l = rule({ name: "l", on: "timer", handle() { throw new Error("y".repeat(8 << 20)); } });
    "#,
            ),
        ],
        5.0,
    );
    assert!(load_error(&results, "huge").contains("fit in one message"), "{results:?}");
    assert_eq!(load_error(&results, "loud"), "");
    harness.invoke(1, "loud.ts#l", json!({}), 5.0);
    let message = harness.error_until_done(1);
    assert!(message.len() < 128 << 10 && message.ends_with("[cut]"), "{} bytes", message.len());
}

/// Deno checks the path a call names, after resolving `..` but not
/// symlinks: a symlink inside a grant that points outside it is followed.
/// The daemon documents this; grants should name directories whose
/// contents the rule's author controls.
#[test]
fn a_symlink_inside_a_grant_is_followed() {
    let directory = scratch("symlink");
    let allowed = directory.join("allowed");
    let outside = directory.join("outside");
    std::fs::create_dir_all(&allowed).unwrap();
    std::fs::create_dir_all(&outside).unwrap();
    std::os::unix::fs::symlink(&outside, allowed.join("link")).unwrap();
    let harness = Harness::start();
    harness.load(
        &[(
            "link",
            &format!(
                r#"
        import {{ rule }} from "meerkat";
        export const l = rule({{ name: "l", on: "timer", async handle() {{
          for (const path of ["{dotdot}", "{link}"]) {{
            try {{ await Deno.writeTextFile(path, ""); console.log("ok"); }} catch (e) {{ console.log(e.name); }}
          }}
        }} }});
    "#,
                dotdot = allowed.join("../outside/a").display(),
                link = allowed.join("link/b").display()
            ),
        )],
        5.0,
    );
    harness.permit("link", granting(&[], &[allowed.to_str().unwrap()]));
    harness.invoke(1, "link.ts#l", json!({}), 10.0);
    assert_eq!(harness.logs_until_done(1), ["NotCapable", "ok"]);
    assert!(outside.join("b").exists());
}

/// A handler that works for a while after an `await`, within its timeout,
/// completes: its continuation may run until the invocation's deadline, and
/// it is not counted against the file's share of its thread.
#[test]
fn a_handler_working_after_an_await_within_its_timeout_completes() {
    let harness = Harness::start();
    harness.load(
        &[(
            "work",
            r#"
        import { rule } from "meerkat";
        export const w = rule({ name: "w", on: "timer", async handle() {
          await null;
          const end = Date.now() + 6000;
          while (Date.now() < end) {}
        } });
        export const after = rule({ name: "after", on: "timer", handle() {} });
    "#,
        )],
        5.0,
    );
    harness.invoke(1, "work.ts#w", json!({}), 10.0);
    harness.logs_until_done(1);
    // Past the duty check that would have charged those six seconds.
    std::thread::sleep(Duration::from_millis(200));
    harness.invoke(2, "work.ts#after", json!({}), 5.0);
    harness.logs_until_done(2);
}

/// Rule code that keeps the runtime from handling its uncaught errors ends
/// its event loop with its own text. That text is cut where the host reports
/// it, so the file alone fails, under its own name.
#[test]
fn an_oversized_error_that_ends_the_event_loop_is_cut() {
    const LOUD: &str = r#"
        Event.prototype.preventDefault = () => {};
        const loud = () => { const e = new Error("x"); e.stack = "a\n" + "x".repeat(5 << 20); throw e; };
    "#;
    let harness = Harness::start();
    let pending = format!("{LOUD}\nawait new Promise(() => setTimeout(loud, 0));\n");
    let results = harness.load(
        &[
            ("pending", &pending),
            ("fine", "import { rule } from \"meerkat\";\nexport const ok = rule({ name: \"ok\", on: \"timer\", handle() {} });\n"),
        ],
        5.0,
    );
    let message = load_error(&results, "pending");
    assert!(message.len() < 128 << 10 && message.ends_with("[cut]"), "{} bytes", message.len());
    harness.invoke(1, "fine.ts#ok", json!({}), 5.0);
    harness.logs_until_done(1);

    let harness = Harness::start();
    let later = format!(
        "{LOUD}\nimport {{ rule }} from \"meerkat\";\nsetTimeout(loud, 300);\nexport const idle = rule({{ name: \"idle\", on: \"timer\", handle() {{}} }});\n"
    );
    assert_eq!(load_error(&harness.load(&[("later", &later)], 5.0), "later"), "");
    let (seen, _) = harness.terminated();
    let (file, rule, _, kind, reason) = fault(&seen);
    assert_eq!((file, rule, kind), ("later.ts", None, FaultKind::Failed));
    assert!(reason.len() < 128 << 10 && reason.ends_with("[cut]"), "{} bytes", reason.len());
}

/// Web Locks are one table for the whole process, so they would let one
/// file see, block or steal another's.
#[test]
fn web_locks_are_not_shared_across_files() {
    let harness = Harness::start();
    harness.load(
        &[(
            "locks",
            r#"
        import { rule } from "meerkat";
        export const l = rule({ name: "l", on: "timer", async handle() {
          for (const [what, run] of [
            ["request", () => navigator.locks.request("x", () => {})],
            ["steal", () => navigator.locks.request("x", { steal: true }, () => {})],
            ["query", () => navigator.locks.query()],
          ]) {
            try { await run(); console.log(what, "returned"); } catch (e) { console.log(what, "threw"); }
          }
        } });
    "#,
        )],
        5.0,
    );
    harness.invoke(1, "locks.ts#l", json!({}), 10.0);
    assert_eq!(harness.logs_until_done(1), ["request threw", "steal threw", "query threw"]);
}

/// Deno KV and Unix socket listeners write files outside the file system
/// that holds protected paths to their real paths, so they are off.
#[test]
fn apis_writing_around_the_guarded_file_system_are_off() {
    let directory = scratch("unguarded");
    let harness = Harness::start();
    harness.load(
        &[(
            "around",
            &format!(
                r#"
        import {{ rule }} from "meerkat";
        export const a = rule({{ name: "a", on: "timer", async handle() {{
          for (const [what, run] of [
            ["kv", () => Deno.openKv("{kv}")],
            ["unix", () => Deno.listen({{ transport: "unix", path: "{socket}" }})],
          ]) {{
            try {{ await run(); console.log(what, "returned"); }} catch (e) {{ console.log(what, "threw"); }}
          }}
        }} }});
    "#,
                kv = directory.join("kv").display(),
                socket = directory.join("socket").display()
            ),
        )],
        5.0,
    );
    let all = directory.to_str().unwrap();
    harness.permit("around", granting(&[all], &[all]));
    harness.invoke(1, "around.ts#a", json!({}), 10.0);
    assert_eq!(harness.logs_until_done(1), ["kv threw", "unix threw"]);
    assert!(!directory.join("kv").exists() && !directory.join("socket").exists());
}

/// Logs carry the rule they name only when it is the worker's own; anything
/// else is the worker's file speaking.
#[test]
fn a_log_line_is_kept_under_its_own_files_rules() {
    let harness = Harness::start();
    let code = |name: &str| {
        format!(
            "import {{ rule }} from \"meerkat\";\nexport const r = rule({{ name: \"{name}\", on: \"timer\", handle() {{}} }});\n"
        )
    };
    harness.load(&[("mine", &code("a")), ("other", &code("b"))], 5.0);
    let worker = harness.host.worker_of("mine").expect("mine is loaded");
    for (named, kept) in [(Some("mine.ts#a"), "mine.ts#a"), (Some("other.ts#b"), "mine.ts"), (None, "mine.ts")] {
        harness.host.log_from(worker, named.map(str::to_owned), "line".into());
        let log = harness.next_log();
        assert_eq!((log.rule.as_deref(), log.message.as_str()), (Some(kept), "line"), "{named:?}");
    }
}

/// The deny side of a file's grants: no path at, inside or above a
/// protected one changes, whatever names it (protected.rs).
#[test]
fn protected_paths_are_held_to_their_real_paths() {
    let directory = scratch("protected");
    let home = directory.join("home");
    let rules = home.join("meerkat/rules");
    let granted = home.join("granted");
    std::fs::create_dir_all(&rules).unwrap();
    std::fs::create_dir_all(&granted).unwrap();
    std::fs::write(rules.join("meerkat.json"), "{}").unwrap();
    std::fs::create_dir_all(home.join("staging")).unwrap();
    // The rules folder as the daemon names it, through a symlinked parent.
    std::os::unix::fs::symlink(&home, directory.join("alias")).unwrap();
    let named = directory.join("alias/meerkat/rules");
    // A symlink inside the grant into the rules folder, one to a file there,
    // and a hard link someone made to a file there.
    std::os::unix::fs::symlink(&rules, granted.join("to-rules")).unwrap();
    std::os::unix::fs::symlink(rules.join("meerkat.json"), granted.join("to-settings")).unwrap();
    std::os::unix::fs::symlink(rules.join("new.ts"), granted.join("dangling")).unwrap();
    std::fs::hard_link(rules.join("meerkat.json"), granted.join("hard")).unwrap();
    let attempts = [
        ("real", format!("Deno.writeTextFile({:?}, '')", rules.join("evil.ts"))),
        ("link", format!("Deno.writeTextFile({:?}, '')", granted.join("to-rules/evil.ts"))),
        ("file link", format!("Deno.writeTextFile({:?}, '')", granted.join("to-settings"))),
        ("dangling", format!("Deno.writeTextFile({:?}, '')", granted.join("dangling"))),
        ("hard link", format!("Deno.writeTextFile({:?}, '')", granted.join("hard"))),
        ("new hard link", format!("Deno.link({:?}, {:?})", granted.join("to-settings"), granted.join("hard2"))),
        ("remove", format!("Deno.remove({:?})", granted.join("to-rules/meerkat.json"))),
        ("rename away", format!("Deno.rename({:?}, {:?})", home.join("meerkat"), home.join("old"))),
        ("rename into", format!("Deno.rename({:?}, {:?})", home.join("staging"), home.join("meerkat"))),
        ("chmod above", format!("Deno.chmod({:?}, 0)", home.join("meerkat"))),
        ("node", format!("fsp.writeFile({:?}, '')", granted.join("to-rules/n.ts"))),
        ("node sync", format!("fs.writeFileSync({:?}, '')", granted.join("to-rules/s.ts"))),
        ("inside grant", format!("Deno.writeTextFile({:?}, '')", granted.join("ok"))),
        ("rename in grant", format!("Deno.rename({:?}, {:?})", granted.join("ok"), granted.join("ok2"))),
        ("read", format!("Deno.readTextFile({:?})", granted.join("to-settings"))),
        // The rules folder by its name on the data volume, and its folder
        // by another case.
        ("data volume", format!("Deno.writeTextFile({:?}, '')", on_data_volume(&rules.join("evil.ts")))),
        ("case", format!("Deno.rename({:?}, {:?})", home.join("MEERKAT"), home.join("old"))),
    ];
    let mut body = String::new();
    for (what, call) in &attempts {
        let _ = writeln!(
            body,
            "try {{ await {call}; console.log({what:?}, 'ok'); }} catch (e) {{ console.log({what:?}, why(e)); }}"
        );
    }
    // node:fs reports the refusal as Node does, by its code.
    let code = format!(
        r#"import {{ rule }} from "meerkat";
        import fs from "node:fs";
        import fsp from "node:fs/promises";
        const why = (e) => (e.name === "PermissionDenied" || e.code === "EACCES" ? "denied" : e.name);
        export const w = rule({{ name: "w", on: "timer", async handle() {{
        {body}}} }});
        "#
    );
    let harness = Harness::start();
    harness.load(&[("guard", &code)], 5.0);
    let home_path = home.to_str().unwrap();
    // Deno compares a call's path with its grants as text, so the data
    // volume's name is granted too.
    let home_alias = on_data_volume(&home).display().to_string();
    let mut permit = granting(&[home_path, &home_alias], &[home_path, &home_alias]);
    permit.deny_write = vec![named.display().to_string()];
    harness.permit("guard", permit);
    harness.invoke(1, "guard.ts#w", json!({}), 20.0);
    let seen = harness.logs_until_done(1);
    let expected: Vec<String> = attempts
        .iter()
        .map(|(what, _)| {
            let outcome = if ["inside grant", "rename in grant", "read"].contains(what) { "ok" } else { "denied" };
            format!("{what} {outcome}")
        })
        .collect();
    assert_eq!(seen, expected);
    assert_eq!(std::fs::read_to_string(rules.join("meerkat.json")).unwrap(), "{}");
    let mut left: Vec<_> = std::fs::read_dir(&rules).unwrap().map(|entry| entry.unwrap().file_name()).collect();
    left.sort();
    assert_eq!(left, ["meerkat.json"]);
    assert!(home.join("meerkat").exists() && home.join("staging").exists());
}

/// A protected path is held by every name on its way, not only its two
/// ends: the settings file is protected where its symlink leads, and with a
/// rules folder named through two symlinks (a stow-style link to its
/// folder, and the folder a link to another), neither link nor the folder
/// holding the second can be moved, which would let a folder of the rule's
/// own take the rules folder's place. A file that does not exist yet cannot
/// be made in another case. Writes beside each still work.
#[test]
fn protected_paths_are_held_along_every_link() {
    let directory = scratch("links");
    let home = directory.join("home");
    let stowed = home.join("stow/cfg/meerkat");
    let real = home.join("code/rules");
    let dotfiles = home.join("dotfiles");
    for folder in [home.join("cfg"), stowed.join("other"), real.clone(), dotfiles.clone(), home.join("prefs")] {
        std::fs::create_dir_all(folder).unwrap();
    }
    std::fs::write(dotfiles.join("meerkat.json"), "{}").unwrap();
    std::os::unix::fs::symlink(&stowed, home.join("cfg/meerkat")).unwrap();
    std::os::unix::fs::symlink(&real, stowed.join("rules")).unwrap();
    std::os::unix::fs::symlink(dotfiles.join("meerkat.json"), real.join("meerkat.json")).unwrap();
    let named = home.join("cfg/meerkat/rules");
    let attempts = [
        ("settings target", format!("Deno.writeTextFile({:?}, '')", dotfiles.join("meerkat.json"))),
        ("settings folder", format!("Deno.rename({:?}, {:?})", dotfiles, home.join("old-dotfiles"))),
        ("beside settings", format!("Deno.writeTextFile({:?}, '')", dotfiles.join("other.json"))),
        ("first link's folder", format!("Deno.rename({:?}, {:?})", stowed, home.join("old-cfg"))),
        ("second link", format!("Deno.remove({:?})", stowed.join("rules"))),
        ("rules folder", format!("Deno.rename({:?}, {:?})", real, home.join("code/old"))),
        ("beside the link", format!("Deno.writeTextFile({:?}, '')", stowed.join("other/x"))),
        ("new file's case", format!("Deno.writeTextFile({:?}, '')", home.join("prefs/X.PLIST"))),
        ("beside new file", format!("Deno.writeTextFile({:?}, '')", home.join("prefs/y.plist"))),
    ];
    let mut body = String::new();
    for (what, call) in &attempts {
        let _ = writeln!(
            body,
            "try {{ await {call}; console.log({what:?}, 'ok'); }} catch (e) {{ console.log({what:?}, why(e)); }}"
        );
    }
    // Refused by protected.rs, or for the new file's case by Deno's own deny
    // list, which compares without case too (protected.rs's folding alone is
    // held to that case by `protected_paths_cover_the_shared_cases`).
    let code = format!(
        r#"import {{ rule }} from "meerkat";
        const why = (e) => (e.name === "PermissionDenied" || e.name === "NotCapable" ? "denied" : e.name);
        export const w = rule({{ name: "w", on: "timer", async handle() {{
        {body}}} }});
        "#
    );
    let harness = Harness::start();
    harness.load(&[("links", &code)], 5.0);
    let home_path = home.to_str().unwrap();
    let mut permit = granting(&[home_path], &[home_path]);
    // As `DaemonPaths.protected` names them; the runtime finds the rest.
    permit.deny_write = [named.clone(), named.join("meerkat.json"), home.join("prefs/x.plist")]
        .iter()
        .map(|path| path.display().to_string())
        .collect();
    harness.permit("links", permit);
    harness.invoke(1, "links.ts#w", json!({}), 20.0);
    let expected: Vec<String> = attempts
        .iter()
        .map(|(what, _)| {
            let outcome = if what.starts_with("beside") { "ok" } else { "denied" };
            format!("{what} {outcome}")
        })
        .collect();
    assert_eq!(harness.logs_until_done(1), expected);
    assert_eq!(std::fs::read_to_string(dotfiles.join("meerkat.json")).unwrap(), "{}");
    assert!(std::fs::read_link(stowed.join("rules")).is_ok() && real.is_dir());
    let mut prefs: Vec<_> =
        std::fs::read_dir(home.join("prefs")).unwrap().map(|entry| entry.unwrap().file_name()).collect();
    prefs.sort();
    assert_eq!(prefs, ["y.plist"]);
}

/// Nothing waits on another program while it holds off every rule's
/// renames (protected.rs): a FIFO with no writer opens at once to read, one
/// with no reader is refused to write rather than waited on, and it is not
/// copied, which would wait to read it. So a rename right after goes
/// through, where it would otherwise wait for a writer that never comes.
#[test]
fn a_fifo_does_not_hold_off_renames() {
    let directory = scratch("fifo");
    let fifo = directory.join("fifo");
    assert!(std::process::Command::new("/usr/bin/mkfifo").arg(&fifo).status().unwrap().success());
    std::fs::create_dir_all(directory.join("a")).unwrap();
    let code = format!(
        r#"import {{ rule }} from "meerkat";
        import fs from "node:fs";
        const fifo = {fifo:?};
        export const r = rule({{ name: "r", on: "timer", async handle() {{
          for (const [what, run] of [
            ["open", async () => (await Deno.open(fifo)).close()],
            ["open sync", () => Deno.openSync(fifo).close()],
            ["node open", () => fs.closeSync(fs.openSync(fifo, "r"))],
            ["open to write", async () => (await Deno.open(fifo, {{ write: true }})).close()],
            ["copy", () => Deno.copyFile(fifo, {copy:?})],
          ]) {{
            try {{ await run(); console.log(what, "ok"); }} catch {{ console.log(what, "threw"); }}
          }}
          Deno.renameSync({a:?}, {b:?});
          console.log("renamed");
        }} }});
        "#,
        copy = directory.join("copy"),
        a = directory.join("a"),
        b = directory.join("b")
    );
    let harness = Harness::start();
    harness.load(&[("fifo", &code)], 5.0);
    let all = directory.to_str().unwrap();
    harness.permit("fifo", granting(&[all], &[all]));
    harness.invoke(1, "fifo.ts#r", json!({}), 10.0);
    assert_eq!(
        harness.logs_until_done(1),
        ["open ok", "open sync ok", "node open ok", "open to write threw", "copy threw", "renamed"]
    );
    assert!(directory.join("b").exists() && !directory.join("copy").exists());
}

/// The read side: nothing at or inside a path protected from reading (the
/// state folder) is read, whatever names it: a symlink to it inside a read
/// grant, or its real path while the daemon names it through a symlinked
/// parent, which Deno's own deny list, comparing text, lets through.
/// Reading elsewhere in the grant, and the folder above it, still works.
#[test]
fn protected_reads_are_held_to_their_real_paths() {
    let directory = scratch("reads");
    let home = directory.join("home");
    let state = home.join("state");
    let granted = home.join("granted");
    std::fs::create_dir_all(&state).unwrap();
    std::fs::create_dir_all(&granted).unwrap();
    std::fs::write(state.join("secret"), "s").unwrap();
    std::fs::write(granted.join("ok"), "ok").unwrap();
    std::os::unix::fs::symlink(&state, granted.join("to-state")).unwrap();
    std::os::unix::fs::symlink(&home, directory.join("alias")).unwrap();
    let named = directory.join("alias/state");
    let link = granted.join("to-state");
    let into = link.join("secret");
    let attempts = [
        ("read", format!("Deno.readTextFile({into:?})")),
        ("read sync", format!("Deno.readTextFileSync({into:?})")),
        ("open", format!("(await Deno.open({into:?})).close()")),
        ("list", format!("Array.fromAsync(Deno.readDir({link:?}))")),
        ("list sync", format!("[...Deno.readDirSync({link:?})]")),
        ("stat", format!("Deno.stat({into:?})")),
        ("real path", format!("Deno.realPath({into:?})")),
        ("copy", format!("Deno.copyFile({into:?}, {:?})", granted.join("copy"))),
        ("node read", format!("fs.readFileSync({into:?})")),
        ("node read async", format!("fsp.readFile({into:?})")),
        ("node open", format!("fs.openSync({into:?}, 'r')")),
        ("node exists", format!("fs.existsSync({into:?}) && fail()")),
        ("by real path", format!("Deno.readTextFile({:?})", state.join("secret"))),
        ("grant", format!("Deno.readTextFile({:?})", granted.join("ok"))),
        ("above", format!("Array.fromAsync(Deno.readDir({home:?}))")),
        ("data volume", format!("Deno.readTextFile({:?})", on_data_volume(&state.join("secret")))),
    ];
    let mut body = String::new();
    for (what, call) in &attempts {
        let _ = writeln!(
            body,
            "try {{ await {call}; console.log({what:?}, 'ok'); }} catch (e) {{ console.log({what:?}, why(e)); }}"
        );
    }
    let code = format!(
        r#"import {{ rule }} from "meerkat";
        import fs from "node:fs";
        import fsp from "node:fs/promises";
        const why = (e) => (e.name === "PermissionDenied" || e.code === "EACCES" ? "denied" : `${{e.name}}: ${{e.message}}`);
        const fail = () => {{ throw new Error("it exists"); }};
        export const r = rule({{ name: "r", on: "timer", async handle() {{
        {body}}} }});
        "#
    );
    let harness = Harness::start();
    harness.load(&[("reads", &code)], 5.0);
    let (home_path, granted_path) = (home.to_str().unwrap(), granted.to_str().unwrap());
    let home_alias = on_data_volume(&home).display().to_string();
    let mut permit = granting(&[home_path, &home_alias], &[granted_path]);
    permit.deny_read = vec![named.display().to_string()];
    permit.deny_write = vec![named.display().to_string()];
    harness.permit("reads", permit);
    harness.invoke(1, "reads.ts#r", json!({}), 20.0);
    let seen = harness.logs_until_done(1);
    let expected: Vec<String> = attempts
        .iter()
        .map(|(what, _)| {
            let outcome = if ["node exists", "grant", "above"].contains(what) { "ok" } else { "denied" };
            format!("{what} {outcome}")
        })
        .collect();
    assert_eq!(seen, expected);
    assert!(!granted.join("copy").exists());
}

/// File watching asks `FSEvents` directly, around the guarded file system, so
/// it is off: a watch through a symlink to the state folder in a read grant
/// would report what changes there, and so would one above it.
#[test]
fn file_watching_around_the_guard_is_off() {
    let directory = scratch("watch");
    let home = directory.join("home");
    let state = home.join("state");
    let granted = home.join("granted");
    std::fs::create_dir_all(&state).unwrap();
    std::fs::create_dir_all(&granted).unwrap();
    std::fs::write(state.join("secret"), "s").unwrap();
    std::fs::write(granted.join("ok"), "ok").unwrap();
    std::os::unix::fs::symlink(&state, granted.join("to-state")).unwrap();
    let link = granted.join("to-state");
    let code = format!(
        r#"import {{ rule }} from "meerkat";
        import fs from "node:fs";
        const why = (e) => (String(e?.message).includes("op is disabled") ? "refused" : `${{e?.name}}: ${{e?.message}}`);
        export const r = rule({{ name: "r", on: "timer", async handle() {{
          for (const [what, watch] of [
            ["deno link", () => Deno.watchFs({link:?})],
            ["deno above", () => Deno.watchFs({home:?})],
          ]) {{
            try {{ watch().close(); console.log(what, "ok"); }} catch (e) {{ console.log(what, why(e)); }}
          }}
          // `fs.watch` reports a watch it could not start as an `error` event.
          const failed = await new Promise((resolve) => {{
            const watcher = fs.watch({home:?});
            watcher.on("error", () => {{ watcher.close(); resolve(true); }});
            setTimeout(() => {{ watcher.close(); resolve(false); }}, 500);
          }});
          console.log("node above", failed ? "refused" : "ok");
        }} }});
        "#
    );
    let harness = Harness::start();
    harness.load(&[("watch", &code)], 5.0);
    let home_path = home.to_str().unwrap();
    let mut permit = granting(&[home_path], &[]);
    permit.deny_read = vec![state.display().to_string()];
    permit.deny_write = vec![state.display().to_string()];
    harness.permit("watch", permit);
    harness.invoke(1, "watch.ts#r", json!({}), 10.0);
    assert_eq!(harness.logs_until_done(1), ["deno link refused", "deno above refused", "node above refused"]);
}

/// A file opened only to read cannot have its mode, owner or times changed
/// through its descriptor, which `node:fs`'s `fchmod`, `fchown` and
/// `futimes` and `Deno.FsFile`'s `utime` do with no check of their own: not
/// a protected folder or file, nor a file only a read grant covers
/// (protected.rs, `GuardedFile`). A file opened to write may still.
#[test]
fn a_file_opened_to_read_keeps_its_mode_owner_and_times() {
    use std::os::unix::fs::PermissionsExt;
    let directory = scratch("descriptors");
    let home = directory.join("home");
    let rules = home.join("meerkat/rules");
    let readable = directory.join("readable");
    std::fs::create_dir_all(&rules).unwrap();
    std::fs::create_dir_all(&readable).unwrap();
    let settings = rules.join("meerkat.json");
    std::fs::write(&settings, "{}").unwrap();
    let plain = readable.join("plain");
    std::fs::write(&plain, "").unwrap();
    std::os::unix::fs::symlink(&settings, home.join("to-settings")).unwrap();
    // Named through a symlinked parent, so Deno's own deny list, which
    // compares text, does not refuse first.
    std::os::unix::fs::symlink(&home, directory.join("alias")).unwrap();
    let named = directory.join("alias/meerkat/rules");
    let state = |path: &std::path::Path| {
        let metadata = std::fs::metadata(path).unwrap();
        (metadata.permissions().mode() & 0o7777, metadata.modified().unwrap())
    };
    let before = [&rules, &settings, &plain].map(|path| state(path));
    let read = |path: &std::path::Path| format!("fs.openSync({path:?}, 'r')");
    let attempts = [
        ("folder fchmod", format!("fs.fchmodSync({}, 0o777)", read(&rules))),
        ("settings fchmod", format!("fs.fchmodSync({}, 0o666)", read(&settings))),
        ("settings fchown", format!("own({})", read(&settings))),
        ("settings futimes", format!("fs.futimesSync({}, 0, 0)", read(&settings))),
        ("plain fchmod", format!("fs.fchmodSync({}, 0o777)", read(&plain))),
        ("plain fchmod async", format!("promised(fs.fchmod, {}, 0o777)", read(&plain))),
        ("plain futimes async", format!("promised(fs.futimes, {}, 0, 0)", read(&plain))),
        ("link utime", format!("(await Deno.open({:?})).utime(0, 0)", home.join("to-settings"))),
        ("written fchmod", format!("fs.fchmodSync(fs.openSync({:?}, 'w'), 0o600)", home.join("written"))),
    ];
    let mut body = String::new();
    for (what, call) in &attempts {
        let _ = writeln!(
            body,
            "try {{ await {call}; console.log({what:?}, 'ok'); }} catch (e) {{ console.log({what:?}, why(e)); }}"
        );
    }
    let code = format!(
        r#"import {{ rule }} from "meerkat";
        import fs from "node:fs";
        const why = (e) => (e.name === "PermissionDenied" || e.code === "EACCES" ? "denied" : `${{e.name}}: ${{e.message}}`);
        const own = (fd) => {{ const {{ uid, gid }} = fs.fstatSync(fd); fs.fchownSync(fd, uid, gid); }};
        const promised = (call, ...args) => new Promise((resolve, reject) => call(...args, (e) => (e ? reject(e) : resolve())));
        export const d = rule({{ name: "d", on: "timer", async handle() {{
        {body}}} }});
        "#
    );
    let harness = Harness::start();
    harness.load(&[("descriptors", &code)], 5.0);
    let (home_path, readable_path) = (home.to_str().unwrap(), readable.to_str().unwrap());
    let mut permit = granting(&[home_path, readable_path], &[home_path]);
    permit.deny_write = vec![named.display().to_string()];
    harness.permit("descriptors", permit);
    harness.invoke(1, "descriptors.ts#d", json!({}), 20.0);
    let seen = harness.logs_until_done(1);
    let expected: Vec<String> = attempts
        .iter()
        .map(|(what, _)| format!("{what} {}", if *what == "written fchmod" { "ok" } else { "denied" }))
        .collect();
    assert_eq!(seen, expected);
    assert_eq!([&rules, &settings, &plain].map(|path| state(path)), before);
}

/// The trigger round two's review found: an async call is checked on the
/// blocking pool, just before it acts, and no rename lands between a check
/// and its call, so swapping a folder for one holding a symlink into the
/// rules folder never sends a write there. Tried in one file, with the swap
/// made in the same tick as the call, and across two files at once.
#[test]
fn a_rename_never_lands_between_a_check_and_its_call() {
    let directory = scratch("swap");
    let home = directory.join("home");
    let rules = home.join("meerkat/rules");
    std::fs::create_dir_all(&rules).unwrap();
    std::fs::write(rules.join("meerkat.json"), "{}").unwrap();
    // In each granted folder: `cur/link` a real folder, and `box/link` a
    // symlink to the rules folder that someone else made.
    let granted = |name: &str| {
        let folder = home.join(name);
        std::fs::create_dir_all(folder.join("cur/link")).unwrap();
        std::fs::create_dir_all(folder.join("box")).unwrap();
        std::os::unix::fs::symlink(&rules, folder.join("box/link")).unwrap();
        folder.display().to_string()
    };
    let (one, two) = (granted("one"), granted("two"));
    let swap = r"
        const swap = (g) => { Deno.renameSync(`${g}/cur`, `${g}/old`); Deno.renameSync(`${g}/box`, `${g}/cur`); };
        const back = (g) => { Deno.renameSync(`${g}/cur`, `${g}/box`); Deno.renameSync(`${g}/old`, `${g}/cur`); };
        const forMs = (ms, work) => { const end = Date.now() + ms; let n = 0; for (; Date.now() < end; n++) work(n); return n; };
    ";
    let file = |body: &str| {
        format!(
            "import {{ rule }} from \"meerkat\";\n{swap}\nexport const r = rule({{ name: \"r\", on: \"timer\", async handle() {{ {body} }} }});\n"
        )
    };
    let tick = file(&format!(
        r#"const g = {one:?};
            for (let i = 0; i < 300; i++) {{
              const pending = Promise.allSettled([
                Deno.writeTextFile(`${{g}}/cur/link/w${{i}}.ts`, ""),
                Deno.mkdir(`${{g}}/cur/link/m${{i}}`),
              ]);
              swap(g);
              await pending;
              back(g);
            }}"#
    ));
    let writer = file(&format!(
        r#"const g = {two:?};
            forMs(2000, (n) => {{ try {{ Deno.writeTextFileSync(`${{g}}/cur/link/s${{n % 50}}.ts`, ""); }} catch {{}} }});"#
    ));
    let renamer = file(&format!(r"const g = {two:?}; forMs(2000, () => {{ swap(g); back(g); }});"));
    let harness = Harness::start();
    let results = harness.load(&[("tick", &tick), ("writer", &writer), ("renamer", &renamer)], 5.0);
    for entry in ["tick", "writer", "renamer"] {
        assert_eq!(load_error(&results, entry), "", "{entry}");
        let home_path = home.to_str().unwrap();
        let mut permit = granting(&[home_path], &[home_path]);
        permit.deny_write = vec![rules.display().to_string()];
        harness.permit(entry, permit);
    }
    harness.invoke(1, "tick.ts#r", json!({}), 30.0);
    assert_eq!(harness.until_done(1).1, None);
    harness.invoke(2, "writer.ts#r", json!({}), 30.0);
    harness.invoke(3, "renamer.ts#r", json!({}), 30.0);
    let mut pending = vec![2, 3];
    while !pending.is_empty() {
        match harness.events.recv_timeout(WAIT).expect("both done") {
            Event::Message(HostToDaemon::InvocationDone { invocation, error }) => {
                assert_eq!(error, None, "{invocation}");
                pending.retain(|done| *done != invocation);
            }
            Event::Message(_) => {}
            Event::Terminated(reason) => panic!("terminated: {reason}"),
        }
    }
    let left: Vec<_> = std::fs::read_dir(&rules).unwrap().map(|entry| entry.unwrap().file_name()).collect();
    assert_eq!(left, ["meerkat.json"], "nothing was written into the rules folder");
    // The writes that were not refused landed in the real folder.
    assert!(std::fs::read_dir(home.join("two/cur/link")).unwrap().count() > 0);
}

/// While the daemon acts on a path for a rule (`hold_rule_renames`, around
/// `files.trash` and `files.setTags`), a rule's rename waits for it, so it
/// cannot swap a folder between the daemon's check and its act.
#[test]
fn a_rename_waits_while_the_daemon_holds_renames() {
    struct Hold(Mutex<Sender<()>>);
    impl crate::PathWork for Hold {
        fn run(&self) {
            self.0.lock().unwrap().send(()).unwrap();
            std::thread::sleep(Duration::from_secs(1));
        }
    }
    let directory = scratch("hold");
    std::fs::create_dir_all(directory.join("a")).unwrap();
    let code = format!(
        r#"import {{ rule }} from "meerkat";
        export const r = rule({{ name: "r", on: "timer", handle() {{
          const began = Date.now();
          Deno.renameSync({a:?}, {b:?});
          console.log(Date.now() - began >= 500 ? "waited" : "did not wait");
        }} }});
        "#,
        a = directory.join("a"),
        b = directory.join("b")
    );
    let harness = Harness::start();
    harness.load(&[("hold", &code)], 5.0);
    let all = directory.to_str().unwrap();
    harness.permit("hold", granting(&[all], &[all]));
    let (holding, held) = channel();
    let holder = std::thread::spawn(move || crate::hold_rule_renames(std::sync::Arc::new(Hold(Mutex::new(holding)))));
    held.recv().unwrap();
    harness.invoke(1, "hold.ts#r", json!({}), 10.0);
    assert_eq!(harness.logs_until_done(1), ["waited"]);
    holder.join().unwrap();
    assert!(directory.join("b").exists());
}

/// `node:fs`'s `cp` clones a folder with `clonefile(2)` (worker.rs,
/// `UNGUARDED_WRITE_OPS`): tried through a symlink into the rules folder
/// (`into`), by its other case and its name on the data volume, and with a
/// filter, which takes its other ops. Makes the folder copied.
fn cp_attempts(directory: &std::path::Path, into: &dyn Fn(&str) -> String) -> Vec<(String, String)> {
    std::fs::create_dir_all(directory.join("granted/payload/sub")).unwrap();
    std::fs::write(directory.join("granted/payload/sub/evil.ts"), "").unwrap();
    let payload = format!("{:?}", directory.join("granted/payload"));
    let upper = format!("{:?}", directory.join("RULES/cp-case"));
    let volume = format!("{:?}", on_data_volume(&directory.join("rules")).join("cp-volume"));
    let filter = "{ recursive: true, filter: () => true }";
    [
        ("sync", format!("fs.cpSync({payload}, {}, {{ recursive: true }})", into("cp-sync"))),
        ("promise", format!("fs.promises.cp({payload}, {}, {{ recursive: true }})", into("cp-promise"))),
        ("case", format!("fs.cpSync({payload}, {upper}, {{ recursive: true }})")),
        ("data volume", format!("fs.cpSync({payload}, {volume}, {{ recursive: true }})")),
        ("filter", format!("fs.promises.cp({payload}, {}, {filter})", into("cp-filter"))),
    ]
    .into_iter()
    .map(|(route, call)| (format!("cp {route}"), call))
    .collect()
}

/// Node APIs that write files their own way (SQLite, WASI, Unix socket
/// listeners, `node:fs`'s `cp`) are refused by every route to them, so none
/// can write into a protected folder through a symlink that Deno's own check
/// lets pass. With `refuseUnguardedWrites` (runtime.js) left out, the static
/// and `getBuiltinModule` routes to SQLite and WASI succeed here; with the
/// `cp` ops on, `cp` through the symlink clones the payload into the rules
/// folder. `node:path` and the guarded `node:fs` keep working.
#[test]
fn apis_writing_around_the_guard_are_refused_by_every_route() {
    let directory = scratch("routes");
    let rules = directory.join("rules");
    let granted = directory.join("granted");
    std::fs::create_dir_all(&rules).unwrap();
    std::fs::create_dir_all(&granted).unwrap();
    std::os::unix::fs::symlink(&rules, granted.join("to-rules")).unwrap();
    let into = |name: &str| format!("{:?}", granted.join("to-rules").join(name));
    let mut attempts: Vec<(String, String)> = Vec::new();
    for (route, module) in [
        ("static", "{ DatabaseSync: StaticDb }".to_owned()),
        ("dynamic", "(await import(\"node:sqlite\"))".to_owned()),
        ("default", "(await import(\"node:sqlite\")).default".to_owned()),
        ("require", "require(\"node:sqlite\")".to_owned()),
        ("builtin", "process.getBuiltinModule(\"node:sqlite\")".to_owned()),
        ("internal", "Deno[Deno.internal].core.ops".to_owned()),
    ] {
        let path = into(&format!("{route}.db"));
        attempts.push((format!("sqlite {route}"), format!("new ({module}).DatabaseSync({path}, {{}})")));
    }
    let preopens = format!("{{ version: \"preview1\", preopens: {{ \"/\": {:?} }} }}", granted.display());
    for (route, module) in [
        ("static", "{ WASI: StaticWasi }"),
        ("dynamic", "(await import(\"node:wasi\"))"),
        ("require", "require(\"node:wasi\")"),
        ("builtin", "process.getBuiltinModule(\"node:wasi\")"),
    ] {
        attempts.push((format!("wasi {route}"), format!("new ({module}).WASI({preopens})")));
    }
    attempts.push((
        "wasi internal".into(),
        "new (Deno[Deno.internal].core.ops.WasiContext)([], [], [], 0, 1, 2, true)".into(),
    ));
    for (route, module) in [
        ("static", "net"),
        ("require", "require(\"node:net\")"),
        ("builtin", "process.getBuiltinModule(\"node:net\")"),
        ("http", "require(\"node:http\")"),
    ] {
        let path = into(&format!("{route}.sock"));
        attempts.push((format!("socket {route}"), format!("listen(({module}).createServer(), {path})")));
    }
    attempts.extend(cp_attempts(&directory, &into));
    attempts.push(("path".into(), "join(\"a\", \"b\") === \"a/b\" || fail()".into()));
    attempts.push(("fs".into(), format!("fs.writeFileSync({:?}, \"\")", granted.join("plain"))));
    let mut body = String::new();
    for (what, call) in &attempts {
        let _ = writeln!(
            body,
            "try {{ await {call}; console.log({what:?}, 'ok'); }} catch (e) {{ console.log({what:?}, why(e)); }}"
        );
    }
    let code = format!(
        r#"import {{ rule }} from "meerkat";
        import {{ DatabaseSync as StaticDb }} from "node:sqlite";
        import {{ WASI as StaticWasi }} from "node:wasi";
        import net from "node:net";
        import fs from "node:fs";
        import {{ join }} from "node:path";
        import {{ createRequire }} from "node:module";
        // CommonJS `require` is off (worker.rs, `NODE_SERVICE_OPS`); asked
        // for here so that route is tried too.
        const require = (id) => createRequire("/")(id);
        const fail = () => {{ throw new Error("wrong"); }};
        // Refused by meerkatd (runtime.js, the loader, a disabled op), by
        // Deno's permissions (NotCapable), or not there at all (Deno's
        // bootstrap removed the classes from the core it shows rule code);
        // anything else is printed whole.
        const refusals = ["not available to rules", "op is disabled", "rules may import"];
        const why = (e) =>
          refusals.some((text) => String(e?.message ?? e).includes(text)) ? "refused"
            : e?.name === "NotCapable" ? "NotCapable"
            : String(e?.message).endsWith("is not a constructor") ? "absent" : `${{e?.name}}: ${{e?.message}}`;
        // Resolves once the server listens; rejects with what refused it.
        const listen = (server, path) => new Promise((resolve, reject) => {{
          server.on("error", reject);
          server.listen(path, () => {{ server.close(); resolve(); }});
        }});
        export const r = rule({{ name: "r", on: "timer", async handle() {{
        {body}}} }});
        "#
    );
    let harness = Harness::start();
    let results = harness.load(&[("routes", &code)], 10.0);
    assert_eq!(load_error(&results, "routes"), "");
    let all = directory.to_str().unwrap();
    // Deno compares a call's path with its grants as text, so the data
    // volume's name is granted too.
    let alias = on_data_volume(&directory).display().to_string();
    let mut permit = granting(&[all, &alias], &[all, &alias]);
    permit.deny_write = vec![rules.display().to_string()];
    harness.permit("routes", permit);
    harness.invoke(1, "routes.ts#r", json!({}), 30.0);
    let seen = harness.logs_until_done(1);
    let expected: Vec<String> = attempts
        .iter()
        .map(|(what, _)| {
            let outcome = match what.as_str() {
                "path" | "fs" => "ok",
                // A Unix socket needs Deno's net permission, which no rule gets.
                "socket static" | "socket builtin" => "NotCapable",
                "sqlite internal" | "wasi internal" => "absent",
                _ => "refused",
            };
            format!("{what} {outcome}")
        })
        .collect();
    assert_eq!(seen, expected);
    assert_eq!(std::fs::read_dir(&rules).unwrap().count(), 0, "the rules folder is untouched");
    assert!(granted.join("plain").exists());
}

/// `deno_node` ops that read services the daemon does not provide throw
/// instead of panicking in V8's call, which would abort the whole process.
#[test]
fn node_apis_needing_services_throw_instead_of_ending_the_process() {
    let harness = Harness::start();
    harness.load(
        &[(
            "services",
            r#"
        import { rule } from "meerkat";
        import { createRequire } from "node:module";
        import tls from "node:tls";
        export const s = rule({ name: "s", on: "timer", async handle() {
          for (const [what, run] of [
            ["require", () => createRequire("/")("node:path")],
            ["constrainedMemory", () => process.constrainedMemory()],
            ["certificates", () => tls.getCACertificates("system")],
          ]) {
            try { await run(); console.log(what, "returned"); } catch (e) { console.log(what, "threw"); }
          }
        } });
        export const after = rule({ name: "after", on: "timer", handle() {} });
    "#,
        )],
        5.0,
    );
    harness.invoke(1, "services.ts#s", json!({}), 10.0);
    assert_eq!(harness.logs_until_done(1), ["require threw", "constrainedMemory threw", "certificates threw"]);
    harness.invoke(2, "services.ts#after", json!({}), 5.0);
    harness.logs_until_done(2);
}
