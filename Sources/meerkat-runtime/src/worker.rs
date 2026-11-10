//! One rule file's worker: a thread running a Deno `MainWorker` with the
//! meerkat extension, fed by the host through an in-process channel.

use std::cell::RefCell;
use std::future::poll_fn;
use std::panic::AssertUnwindSafe;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use deno_core::{OpState, op2, v8};
use deno_error::JsErrorBox;
use deno_resolver::npm::{DenoInNpmPackageChecker, NpmResolver};
use deno_runtime::deno_permissions::{Permissions, PermissionsContainer, PermissionsOptions};
use deno_runtime::permissions::RuntimePermissionDescriptorParser;
use deno_runtime::worker::{MainWorker, WorkerOptions, WorkerServiceOptions};
use deno_runtime::{BootstrapOptions, FeatureChecker};
use serde::Serialize;
use serde_json::value::RawValue;
use tokio::sync::mpsc::UnboundedReceiver;

use crate::host::{self, Shared};
use crate::loader::{MemoryLoader, RuleModules, module_specifier};
use crate::protected::{GuardedFs, Protected};
use crate::protocol::{FilePermissions, HandlerError, HostLogLevel, HostToDaemon, MAXIMUM_MESSAGE_TEXT, MAXIMUM_TEXT};
use crate::watchdog::WorkerId;

type Sys = sys_traits::impls::RealSys;
type Parser = RuntimePermissionDescriptorParser<Sys>;

/// The Deno release these crates are (`DENO_VERSION` in deno.bzl), which
/// rule code reads as `Deno.version.deno`.
pub const DENO_VERSION: &str = env!("DENO_VERSION");
/// Each file's JavaScript heap. Past it the file's worker is stopped rather
/// than letting V8 abort the daemon. Memory outside the heap (`ArrayBuffer`
/// contents, buffers Deno's ops hold) is not counted, and not bounded per
/// file: docs/design/meerkatd.md, "Known limits", says why.
const HEAP_LIMIT: usize = 256 << 20;
/// More than V8's largest single object: a string reaches about 512 MiB and
/// an array about 1 GiB.
const LARGEST_ALLOCATION: usize = 2 << 30;
/// Marks text `cut` shortened.
const CUT: &str = " [cut]";

/// Why a worker past `HEAP_LIMIT` stopped, following the file's or rule's
/// name.
pub fn heap_exhausted() -> String {
    format!("passed its JavaScript heap limit of {} MiB", HEAP_LIMIT >> 20)
}

pub enum Inbound {
    Js(JsMessage),
    /// Replaces what the file's code may do through Deno's APIs.
    Permit(FilePermissions),
}

/// A message for runtime.js's dispatcher (`dispatch`), which handles these
/// and throws on any other `type`. JSON the daemon sent goes in as it came,
/// checked to be JSON where the host received it.
#[derive(Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum JsMessage {
    /// The file to load, by the name the host gives it and its module URL,
    /// with the daemon's effect table.
    Load {
        file: String,
        url: String,
        effects: Box<RawValue>,
    },
    /// Run the handler called `name`, handing it `rule`, its id.
    Invoke {
        invocation: u64,
        rule: String,
        name: String,
        event: Box<RawValue>,
    },
    EffectSucceeded {
        local: u64,
        value: Box<RawValue>,
    },
    EffectFailed {
        local: u64,
        message: String,
    },
}

/// How the host stops a worker from another thread.
#[derive(Default)]
pub struct WorkerControl {
    isolate: Mutex<Option<v8::IsolateHandle>>,
    stopping: AtomicBool,
    stop: tokio::sync::Notify,
}

impl WorkerControl {
    /// Interrupts any JavaScript the worker runs and ends its thread.
    pub fn stop(&self) {
        self.stopping.store(true, Ordering::SeqCst);
        if let Some(isolate) = self.isolate.lock().unwrap().as_ref() {
            isolate.terminate_execution();
        }
        self.stop.notify_one();
    }

    pub fn is_stopping(&self) -> bool {
        self.stopping.load(Ordering::SeqCst)
    }
}

pub struct WorkerSpec {
    pub id: WorkerId,
    pub entry: String,
    /// The file's name as the host gives it (host.rs).
    pub file: String,
    pub rules: Arc<RuleModules>,
}

/// What the ops reach the host through.
struct WorkerContext {
    host: Arc<Shared>,
    id: WorkerId,
    parser: Arc<Parser>,
    /// What the file's `GuardedFs` refuses to change or read, set with each
    /// permit.
    protected: Arc<Protected>,
}

struct Inbox(Rc<tokio::sync::Mutex<UnboundedReceiver<Inbound>>>);

/// Starts the worker's thread. When it ends for any reason (stopped, its
/// event loop failed, a panic in Rust code this thread runs itself), the
/// host hears about it once.
///
/// Not every panic gets here: Deno's ops are `extern "C"` functions V8
/// calls, and a panic unwinding out of one aborts the process. So a panic
/// in a synchronous op, or in the synchronous part of an async one, ends
/// the daemon; only worker setup and the futures of async ops, polled from
/// the event loop below, are caught (docs/design/meerkatd.md, "Known
/// limits").
pub fn spawn(spec: WorkerSpec, inbox: UnboundedReceiver<Inbound>, control: Arc<WorkerControl>, host: Arc<Shared>) {
    let name = format!("meerkat {}", spec.file);
    let id = spec.id;
    let thread = std::thread::Builder::new().name(name).stack_size(8 << 20).spawn({
        let host = host.clone();
        move || {
            let outcome = std::panic::catch_unwind(AssertUnwindSafe(|| run(spec, inbox, &control, host.clone())));
            // `run` returns `Ok` only once the host stopped the worker.
            let error = match outcome {
                Ok(Ok(())) => return,
                Ok(Err(error)) => error,
                Err(panic) => format!("the runtime panicked: {}", panic_message(&panic)),
            };
            if !control.is_stopping() {
                host.worker_exited(id, error);
            }
        }
    });
    if let Err(error) = thread {
        host.worker_exited(id, format!("could not start a thread: {error}"));
    }
}

fn panic_message(panic: &Box<dyn std::any::Any + Send>) -> String {
    panic
        .downcast_ref::<&str>()
        .map(std::string::ToString::to_string)
        .or_else(|| panic.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "unknown panic".into())
}

fn run(
    spec: WorkerSpec,
    inbox: UnboundedReceiver<Inbound>,
    control: &WorkerControl,
    host: Arc<Shared>,
) -> Result<(), String> {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| e.to_string())?;
    runtime.block_on(async {
        let parser = Arc::new(Parser::new(Sys::default()));
        let protected = Arc::new(Protected::default());
        let mut worker = make_worker(&spec, parser.clone(), protected.clone())?;
        let isolate = worker.js_runtime.v8_isolate().thread_safe_handle();
        *control.isolate.lock().unwrap() = Some(isolate.clone());
        if control.is_stopping() {
            return Ok(());
        }
        // V8 aborts the process when a heap is exhausted; stopping the
        // worker first keeps that to this file.
        let heap_host = host.clone();
        let id = spec.id;
        worker.js_runtime.add_near_heap_limit_callback(move |current, _initial| {
            isolate.terminate_execution();
            heap_host.worker_out_of_memory(id);
            // Room to unwind. The worker is ending, so this is a limit and
            // not memory in use, and it has to fit whatever allocation got
            // here: V8 asks once and aborts if that one still doesn't fit.
            current + LARGEST_ALLOCATION
        });
        {
            let state = worker.js_runtime.op_state();
            let mut state = state.borrow_mut();
            state.put(WorkerContext { host: host.clone(), id, parser, protected });
            state.put(Inbox(Rc::new(tokio::sync::Mutex::new(inbox))));
        }
        worker
            .execute_script(
                "ext:meerkat_runtime/start",
                deno_core::ModuleCodeString::from_static("globalThis[Symbol.for(\"meerkat.start\")]()"),
            )
            .map_err(|e| e.to_string())?;

        let watchdog = &host.watchdog;
        let event_loop = poll_fn(|cx| {
            watchdog.poll_began(id, Instant::now());
            let poll = worker.js_runtime.poll_event_loop(cx, Default::default());
            watchdog.poll_ended(id, Instant::now());
            poll
        });
        tokio::select! {
            biased;
            () = control.stop.notified() => Ok(()),
            result = event_loop => match result {
                Ok(()) => Err("its event loop ended".into()),
                Err(error) => Err(error.to_string()),
            },
        }
    })
}

fn make_worker(spec: &WorkerSpec, parser: Arc<Parser>, protected: Arc<Protected>) -> Result<MainWorker, String> {
    let main = module_specifier(&spec.entry);
    let permissions =
        Permissions::from_options(parser.as_ref(), &PermissionsOptions::default()).map_err(|e| e.to_string())?;
    let services = WorkerServiceOptions::<DenoInNpmPackageChecker, NpmResolver<Sys>, Sys> {
        deno_rt_native_addon_loader: None,
        module_loader: Rc::new(MemoryLoader { rules: spec.rules.clone() }),
        permissions: PermissionsContainer::new(parser, permissions),
        blob_store: Arc::new(deno_runtime::deno_web::BlobStore::default()),
        broadcast_channel: Default::default(),
        feature_checker: feature_checker(),
        node_services: Default::default(),
        npm_process_state_provider: Default::default(),
        root_cert_store_provider: Default::default(),
        fetch_dns_resolver: Default::default(),
        shared_array_buffer_store: Default::default(),
        compiled_wasm_module_store: Default::default(),
        v8_code_cache: Default::default(),
        fs: Arc::new(GuardedFs::new(protected)),
        bundle_provider: None,
    };
    let options = WorkerOptions {
        bootstrap: BootstrapOptions {
            deno_version: DENO_VERSION.into(),
            user_agent: format!("meerkatd (Deno/{DENO_VERSION})"),
            ..Default::default()
        },
        extensions: vec![meerkat_runtime::init()],
        startup_snapshot: deno_snapshots::CLI_SNAPSHOT,
        residual_lazy_js_sources: deno_snapshots::RESIDUAL_LAZY_JS,
        residual_lazy_esm_sources: deno_snapshots::RESIDUAL_LAZY_ESM,
        create_params: Some(v8::CreateParams::default().heap_limits(0, HEAP_LIMIT)),
        ..Default::default()
    };
    Ok(MainWorker::bootstrap_from_options(&main, services, options))
}

/// Applies `permissions` to the file's code from its next Deno call on.
///
/// Deno reads the permissions container from the op state on every check,
/// so replacing it there is enough. Its deny list compares paths as named;
/// `GuardedFs` holds both deny lists to real paths.
fn apply(state: &mut OpState, permissions: &FilePermissions) -> Result<(), String> {
    // An empty list must stay `None`: in Deno's options `Some(vec![])` means
    // "everything", as `--allow-write` with no value does.
    let list = |paths: &Vec<String>| (!paths.is_empty()).then(|| paths.clone());
    let options = PermissionsOptions {
        allow_read: list(&permissions.read),
        allow_write: list(&permissions.write),
        deny_read: list(&permissions.deny_read),
        deny_write: list(&permissions.deny_write),
        prompt: false,
        ..Default::default()
    };
    let context = state.borrow::<WorkerContext>();
    let parser = context.parser.clone();
    context.protected.set(&permissions.deny_write, &permissions.deny_read);
    let granted = Permissions::from_options(parser.as_ref(), &options).map_err(|e| e.to_string())?;
    state.put(PermissionsContainer::new(parser, granted));
    Ok(())
}

// ----------------------------------------------------------------------- ops

deno_core::extension!(
    meerkat_runtime,
    ops = [
        op_meerkat_next,
        op_meerkat_loaded,
        op_meerkat_begin_invocation,
        op_meerkat_end_segment,
        op_meerkat_done,
        op_meerkat_effect,
        op_meerkat_log,
    ],
    esm_entry_point = "ext:meerkat_runtime/runtime.js",
    middleware = disable_ops,
    customizer = embed_runtime_js,
);

/// Compiles js/runtime.js into the binary. Not `esm = [dir "js", ...]`: in
/// `deno_core` that form records the file's path, to be read while building a
/// snapshot, and this extension is not in the snapshot, so the daemon would
/// read it at run time from wherever the build's checkout was.
fn embed_runtime_js(extension: &mut deno_core::Extension) {
    extension.esm_files = std::borrow::Cow::Owned(vec![deno_core::ExtensionFileSource::new(
        "ext:meerkat_runtime/runtime.js",
        deno_core::ascii_str_include!(concat!(env!("CARGO_MANIFEST_DIR"), "/js/runtime.js")),
    )]);
}

/// Rule code shares the daemon's process, so nothing it runs may act on the
/// whole process: end it, signal it, change its working directory, umask,
/// title, terminal mode or V8's flags, replace the heap-limit handler that
/// keeps an exhausted heap from aborting it, take over its signals, open an
/// inspector, load native code or start workers. These ops throw instead (or
/// do nothing, if V8 compiled a fast call to them). Several are reachable
/// without any permission (`process.abort()`, `process.kill(process.pid)`,
/// `v8.setFlagsFromString()`), which is why permissions alone are not enough.
const PROCESS_WIDE_OPS: [&str; 13] = [
    "op_exit",
    "op_process_abort",
    "op_node_process_kill",
    "op_fs_chdir",
    "op_fs_umask",
    "op_node_process_set_title",
    "op_set_raw",
    "op_v8_set_flags_from_string",
    "op_v8_set_heap_snapshot_near_heap_limit",
    "op_signal_bind",
    "op_inspector_open",
    "op_napi_open",
    "op_create_worker",
];

/// Deno exits the process when an API behind an unstable flag is called with
/// the flag off, before any permission check and past any `catch`. Without
/// that exit the call carries on to its permission check, so what the flag
/// guarded stays behind the rule's grants.
fn feature_checker() -> Arc<FeatureChecker> {
    let mut checker = FeatureChecker::default();
    checker.set_exit_cb(Box::new(|_feature, _api| {}));
    Arc::new(checker)
}

/// Web Locks are one table for the whole process (`deno_web`'s `LOCK_STATE`),
/// so through them one rule file could list, block or steal another file's
/// locks. The unit of isolation is the file, and rules of one file share a
/// worker and can coordinate in memory, so locks are off: `request` and
/// `query` throw, and nothing else is reachable without a lock.
const CROSS_FILE_OPS: [&str; 2] = ["op_lock_manager_request", "op_lock_manager_query"];

/// Ops that create or write files with `std` or `libc` directly rather than
/// through the worker's file system, which holds protected paths to their
/// real paths (protected.rs): Deno KV, SQLite's backup, Unix socket
/// listeners, and `node:fs`'s `cp`, which clones a folder whose destination
/// does not exist with `clonefile(2)` and copies a symlink by making one past
/// Deno's check for symlinks. Deno's permission check alone would let them
/// reach a protected path through a symlink. Its other `cp` ops only prepare
/// those, so the whole family is off: copy with `copyFile` and `mkdir`.
///
/// What was audited, at `DENO_RUNTIME_VERSION` (deno.bzl), and must be again
/// when it moves: every op and native class of `deno_fs`, `deno_node`,
/// `deno_node_sqlite`, `deno_io`, `deno_net`, `deno_kv`, `deno_cache` and
/// `deno_webstorage` that creates, links, renames, clones or writes a path.
/// The rest reach paths through the worker's file system; WASI and
/// `node:sqlite` are native classes, off in runtime.js; the Cache API and
/// `localStorage` have no folder (the worker is given none); `node:net`
/// sockets need Deno's net permission, which no rule gets.
const UNGUARDED_WRITE_OPS: [&str; 11] = [
    "op_kv_database_open",
    "op_node_database_backup",
    "op_net_listen_unix",
    "op_net_listen_unixpacket",
    "op_node_unstable_net_listen_unixpacket",
    "op_node_cp_sync",
    "op_node_cp_fast",
    "op_node_cp_validate_and_prepare",
    "op_node_cp_check_paths_recursive",
    "op_node_cp_on_file",
    "op_node_cp_on_link",
];

/// `deno_node` ops that read services the daemon does not give its workers
/// (`node_services`: a Node resolver, a `require` loader, the file system as
/// `sys`). Each would panic on the missing service inside an `extern "C"`
/// function V8 calls, which aborts the whole daemon, and `createRequire("/")`
/// or `process.constrainedMemory()` from rule code reaches one. Rules are ES
/// modules and import only the rules and Deno's own modules, so Node's
/// `require` and these few lookups throw instead.
const NODE_SERVICE_OPS: [&str; 18] = [
    "op_require_node_module_paths",
    "op_require_is_deno_dir_package",
    "op_require_resolve_deno_dir",
    "op_require_is_maybe_cjs",
    "op_require_try_self",
    "op_require_real_path",
    "op_require_stat",
    "op_require_read_file",
    "op_require_resolve_exports",
    "op_require_read_package_scope",
    "op_require_package_imports_resolve",
    "op_require_init_paths",
    "op_require_resolve_lookup_paths",
    "op_node_call_is_from_dependency",
    "op_node_in_npm_package",
    "op_worker_threads_filename",
    "op_node_process_constrained_memory",
    "op_node_get_ca_certificates",
];

/// File watching (`Deno.watchFs`, and `node:fs`'s `watch` built on it) asks
/// `FSEvents` directly, not the worker's file system, so a watch through a
/// symlink in a read grant, or one above the state folder (`FSEvents` watches
/// recursively), would report changes inside it. Rules watch files through
/// the `fs.change` event instead.
const UNGUARDED_READ_OPS: [&str; 1] = ["op_fs_events_open"];

/// Every op switched off.
const DISABLED_OPS: [&[&str]; 5] =
    [&PROCESS_WIDE_OPS, &CROSS_FILE_OPS, &UNGUARDED_WRITE_OPS, &UNGUARDED_READ_OPS, &NODE_SERVICE_OPS];

fn disable_ops(op: deno_core::OpDecl) -> deno_core::OpDecl {
    if DISABLED_OPS.iter().any(|ops| ops.contains(&op.name)) { op.disable() } else { op }
}

fn context(state: &OpState) -> (Arc<Shared>, WorkerId) {
    let context = state.borrow::<WorkerContext>();
    (context.host.clone(), context.id)
}

/// The next message for the dispatcher; null once the host is gone.
#[op2]
#[string]
async fn op_meerkat_next(state: Rc<RefCell<OpState>>) -> Option<String> {
    let inbox = state.borrow().borrow::<Inbox>().0.clone();
    let mut inbox = inbox.lock().await;
    loop {
        match inbox.recv().await? {
            Inbound::Js(message) => match serde_json::to_string(&message) {
                Ok(text) => return Some(text),
                // Strings, numbers and checked JSON: not reached. An
                // invocation is still answered, or the daemon would wait on
                // it until it stops the host as unresponsive.
                Err(error) => {
                    let (host, id) = context(&state.borrow());
                    let reason = format!("could not encode a message for the runtime: {error}");
                    match message {
                        JsMessage::Invoke { invocation, .. } => {
                            host.invocation_done(id, invocation, Some(HandlerError::new(reason)));
                        }
                        _ => host.send(HostToDaemon::Log { rule: None, level: HostLogLevel::Error, message: reason }),
                    }
                }
            },
            Inbound::Permit(permissions) => {
                let result = apply(&mut state.borrow_mut(), &permissions);
                if let Err(error) = result {
                    let (host, _) = context(&state.borrow());
                    host.send(HostToDaemon::Log {
                        rule: None,
                        level: HostLogLevel::Error,
                        message: format!("could not apply permissions: {error}"),
                    });
                }
            }
        }
    }
}

/// Text cut to at most `MAXIMUM_TEXT` bytes, on a character boundary, its
/// end marked.
pub(crate) fn cut(mut text: String) -> String {
    if text.len() > MAXIMUM_TEXT {
        let mut end = MAXIMUM_TEXT - CUT.len();
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
        text.push_str(CUT);
    }
    text
}

/// A failure as runtime.js describes it (JSON of `HandlerError`), its
/// message and stack cut.
fn handler_error(text: String) -> HandlerError {
    let error = serde_json::from_str(&text).unwrap_or_else(|_| HandlerError::new(text));
    HandlerError { message: cut(error.message), stack: error.stack.map(cut) }
}

/// The definitions are checked against the message limit as the daemon
/// will receive them (host.rs); text longer than that limit is refused here
/// unread.
#[op2]
fn op_meerkat_loaded(state: &mut OpState, #[string] definitions: Option<String>, #[string] error: Option<String>) {
    let (host, id) = context(state);
    let result = match (definitions, error) {
        (Some(text), _) => host::definitions_fit(text.len()).and_then(|()| {
            serde_json::from_str::<Vec<serde_json::Value>>(&text)
                .map_err(|e| HandlerError::new(format!("the file did not report its rules: {e}")))
        }),
        (None, Some(text)) => Err(handler_error(text)),
        (None, None) => Err(HandlerError::new("the file did not report its rules")),
    };
    host.worker_loaded(id, result);
}

#[op2(fast)]
fn op_meerkat_begin_invocation(state: &mut OpState, #[number] invocation: u64, #[string] rule: String) {
    let (host, id) = context(state);
    host.begin_invocation(id, invocation, rule);
}

#[op2(fast)]
fn op_meerkat_end_segment(state: &mut OpState) {
    let (host, id) = context(state);
    host.watchdog.segment_ended(id, Instant::now());
}

#[op2]
fn op_meerkat_done(state: &mut OpState, #[number] invocation: u64, #[string] error: Option<String>) {
    let (host, id) = context(state);
    host.invocation_done(id, invocation, error.map(handler_error));
}

#[op2(fast)]
fn op_meerkat_effect(
    state: &mut OpState,
    #[number] local: u64,
    #[number] invocation: u64,
    #[string] rule: String,
    #[string] request: String,
) -> Result<(), JsErrorBox> {
    // The message to the daemon carries the rule's id beside the request.
    let room = MAXIMUM_MESSAGE_TEXT.saturating_sub(rule.len());
    if request.len() > room {
        return Err(JsErrorBox::range_error(format!("an effect request may be at most {room} bytes")));
    }
    // Checked here so the handler hears of malformed JSON as a TypeError;
    // the daemon decodes it again, as it trusts nothing rule code sends.
    serde_json::from_str::<&serde_json::value::RawValue>(&request)
        .map_err(|e| JsErrorBox::type_error(format!("the effect request is not JSON: {e}")))?;
    let (host, id) = context(state);
    host.effect(id, local, invocation, rule, request);
    Ok(())
}

#[op2]
fn op_meerkat_log(
    state: &mut OpState,
    #[string] rule: Option<String>,
    #[string] level: String,
    #[string] message: String,
) {
    let (host, id) = context(state);
    host.log(id, rule, HostLogLevel::parse(&level), cut(message));
}

#[cfg(test)]
mod tests {
    use deno_core::ExtensionFileSourceCode;
    use deno_runtime::BootstrapOptions;

    /// The installed daemon has no checkout to read JavaScript from: every
    /// source of the runtime's extension must be in the binary.
    #[test]
    #[allow(deprecated, reason = "IncludedInBinary is what ExtensionFileSource::new builds")]
    fn the_runtime_javascript_is_compiled_in() {
        let extension = super::meerkat_runtime::init();
        assert!(!extension.esm_files.is_empty());
        for file in extension.esm_files.iter().chain(extension.js_files.iter()) {
            assert!(
                matches!(file.code, ExtensionFileSourceCode::IncludedInBinary(_)),
                "{} is {:?}, read from disk at run time",
                file.specifier,
                file.code
            );
        }
    }

    /// The declarations rule code is checked against, and the version it
    /// reads, are `DENO_VERSION`'s, a Deno release built on
    /// `DENO_RUNTIME_VERSION` (both in deno.bzl). The default `deno_version`
    /// of `deno_runtime` is its own crate version, so this compares that with
    /// the `deno_runtime` actually linked.
    #[test]
    fn the_pinned_deno_release_matches_the_linked_deno_runtime() {
        assert_eq!(
            BootstrapOptions::default().deno_version,
            env!("DENO_RUNTIME_VERSION"),
            "deno_runtime changed: re-audit the ops that write around the guarded file system \
             (`UNGUARDED_WRITE_OPS`), then in Sources/meerkat-runtime/deno.bzl set DENO_VERSION to the Deno \
             release built on it, with its libraries' hashes, and DENO_RUNTIME_VERSION to match"
        );
    }

    /// An op is switched off by name, so one Deno renamed would be on again
    /// with nothing failing: each name must be an op the worker registers.
    #[test]
    fn every_disabled_op_is_registered() {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        let registered = runtime.block_on(async {
            let spec = super::WorkerSpec {
                id: 0,
                entry: "ops".into(),
                file: "ops.ts".into(),
                rules: std::sync::Arc::new(crate::loader::RuleModules {
                    modules: std::collections::HashMap::new(),
                    rejected: std::collections::HashMap::new(),
                }),
            };
            let parser = std::sync::Arc::new(super::Parser::new(super::Sys::default()));
            let worker = super::make_worker(&spec, parser, std::sync::Arc::default()).unwrap();
            worker.js_runtime.op_names()
        });
        let missing: Vec<_> =
            super::DISABLED_OPS.iter().flat_map(|ops| ops.iter()).filter(|op| !registered.contains(op)).collect();
        assert!(missing.is_empty(), "no longer ops of this Deno: {missing:?}");
    }
}
