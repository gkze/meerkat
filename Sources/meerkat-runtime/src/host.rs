//! One handler host: the rule set the daemon loaded into it, a worker per
//! rule file, the watchdog, and the single thread that delivers messages to
//! the daemon.
//!
//! A host loads one rule set, once; a reload starts a new host. It can stop
//! at any moment: the daemon stopped it, or a rule file's code ended it (the
//! watchdog found JavaScript stuck, a file's worker failed after loading),
//! which the host reports as a `Fault` naming the file first. The daemon
//! then hears `terminated`, after every message the host sent, and restarts
//! it on its own policy. A file that fails while loading fails alone.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, SyncSender, sync_channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::value::RawValue;
use tokio::sync::mpsc::{UnboundedSender, unbounded_channel};

use crate::loader::{RuleModules, module_specifier};
use crate::protocol::{
    DaemonToHost, EffectOutcome, EntryResult, FaultKind, HandlerError, HostEntry, HostLogLevel, HostModule,
    HostToDaemon, MAXIMUM_MESSAGE_TEXT, MAXIMUM_RULE_NAME,
};
use crate::watchdog::{Finding, Holder, Watchdog, WorkerId};
use crate::worker::{self, Inbound, JsMessage, WorkerControl, WorkerSpec};

/// Where the host's messages go: the daemon's delegate.
pub trait Delivery: Send + 'static {
    fn message(&mut self, message: HostToDaemon);
    /// Called once, after every message.
    fn terminated(&mut self, reason: &str);
}

/// Messages waiting for the delivery thread. A daemon that stops reading
/// eventually blocks the workers writing, rather than letting the queue
/// grow without bound.
const OUTBOUND_CAPACITY: usize = 4096;
const WATCHDOG_INTERVAL: Duration = Duration::from_millis(50);

enum Outbound {
    Message(HostToDaemon),
    Terminated(String),
}

pub struct Host {
    shared: Arc<Shared>,
    commands: std::sync::mpsc::Sender<Command>,
}

/// What the daemon asks for. Handled on the host's control thread, so the
/// daemon's call never blocks on a full delivery queue that only the daemon
/// itself can drain.
enum Command {
    Message(DaemonToHost),
    Stop(String),
}

pub struct Shared {
    outbound: Mutex<Option<SyncSender<Outbound>>>,
    state: Mutex<State>,
    pub(crate) watchdog: Watchdog,
    next_call: AtomicU64,
    next_worker: AtomicU64,
    /// Halts the host once, after the next invoke is checked and before it
    /// is routed: the window a `stop` on the daemon's thread can fall in.
    #[cfg(test)]
    halt_before_dispatch: std::sync::atomic::AtomicBool,
}

#[derive(Default)]
struct State {
    terminated: bool,
    workers: HashMap<WorkerId, Worker>,
    by_entry: HashMap<String, WorkerId>,
    /// Rule id to the worker that runs it and the rule's name there.
    by_rule: HashMap<String, (WorkerId, String)>,
    /// Effect call id to the worker that made it and the call's number there.
    calls: HashMap<u64, (WorkerId, u64)>,
    /// Invocations sent to a worker that it has not begun: the worker, the
    /// rule and the daemon's timeout. Rule code supplies the ids it begins
    /// with, so the host holds them to what it sent.
    dispatched: HashMap<u64, (WorkerId, String, Duration)>,
    load: Load,
}

/// A host loads one rule set, once.
#[derive(Default)]
enum Load {
    #[default]
    NotRequested,
    Pending(PendingLoad),
    Finished,
}

struct Worker {
    entry: String,
    /// What the host calls the file everywhere, as the daemon named it.
    file: String,
    inbox: UnboundedSender<Inbound>,
    control: Arc<WorkerControl>,
    loading: bool,
    /// Set when the worker passed its heap limit, with whoever held its
    /// thread then: the worker's exit is that fault.
    out_of_memory: Option<Holder>,
}

struct PendingLoad {
    entries: Vec<String>,
    results: HashMap<String, EntryResult>,
}

impl Host {
    pub fn start(delivery: impl Delivery) -> Host {
        let (sender, receiver) = sync_channel(OUTBOUND_CAPACITY);
        let shared = Arc::new(Shared {
            outbound: Mutex::new(Some(sender)),
            state: Mutex::new(State::default()),
            watchdog: Watchdog::default(),
            next_call: AtomicU64::new(1),
            next_worker: AtomicU64::new(1),
            #[cfg(test)]
            halt_before_dispatch: std::sync::atomic::AtomicBool::new(false),
        });
        std::thread::Builder::new()
            .name("meerkat delivery".into())
            .spawn(move || deliver(receiver, delivery))
            .expect("the delivery thread starts");
        let watchdog = Arc::downgrade(&shared);
        std::thread::Builder::new()
            .name("meerkat watchdog".into())
            .spawn(move || {
                loop {
                    std::thread::sleep(WATCHDOG_INTERVAL);
                    let Some(shared) = watchdog.upgrade() else { return };
                    if shared.state.lock().unwrap().terminated {
                        return;
                    }
                    for finding in shared.watchdog.check(Instant::now()) {
                        shared.act(finding);
                    }
                }
            })
            .expect("the watchdog thread starts");
        shared.send(HostToDaemon::Ready);
        let (commands, receiver) = std::sync::mpsc::channel();
        let control = shared.clone();
        std::thread::Builder::new()
            .name("meerkat control".into())
            .spawn(move || {
                for command in receiver {
                    match command {
                        Command::Message(message) => control.receive(message),
                        Command::Stop(reason) => control.shutdown(&reason),
                    }
                }
            })
            .expect("the control thread starts");
        Host { shared, commands }
    }

    /// One message from the daemon. Never blocks.
    pub fn receive(&self, message: DaemonToHost) {
        let _ = self.commands.send(Command::Message(message));
    }

    /// Interrupts every worker now; `terminated` follows on the control
    /// thread. Never blocks.
    pub fn stop(&self, reason: &str) {
        self.shared.halt();
        let _ = self.commands.send(Command::Stop(reason.to_owned()));
    }
}

#[cfg(test)]
impl Host {
    /// `stop`'s first half alone: halted, with the control thread yet to
    /// close, as when an earlier message is still queued there.
    pub(crate) fn halt(&self) {
        self.shared.halt();
    }

    /// Halts the host between checking the next invoke and routing it.
    pub(crate) fn halt_before_next_dispatch(&self) {
        self.shared.halt_before_dispatch.store(true, Ordering::Relaxed);
    }

    /// The worker running `entry`, to speak as it.
    pub(crate) fn worker_of(&self, entry: &str) -> Option<WorkerId> {
        self.shared.state.lock().unwrap().by_entry.get(entry).copied()
    }

    /// A log line as `worker`'s code would send it through its op.
    pub(crate) fn log_from(&self, worker: WorkerId, rule: Option<String>, message: String) {
        self.shared.log(worker, rule, HostLogLevel::Info, message);
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        self.stop("released");
    }
}

fn deliver(receiver: Receiver<Outbound>, mut delivery: impl Delivery) {
    for item in receiver {
        match item {
            Outbound::Message(message) => delivery.message(message),
            Outbound::Terminated(reason) => {
                delivery.terminated(&reason);
                return;
            }
        }
    }
}

impl Shared {
    pub(crate) fn send(&self, message: HostToDaemon) {
        // The sender is cloned out of the lock: a full queue blocks only the
        // caller, never the host's state.
        let sender = self.outbound.lock().unwrap().clone();
        if let Some(sender) = sender {
            let _ = sender.send(Outbound::Message(message));
        }
    }

    /// The daemon's values are checked here, where they enter: a duration
    /// that is not one, or JSON that is not, fails what it was sent for.
    fn receive(self: &Arc<Self>, message: DaemonToHost) {
        match message {
            DaemonToHost::Load { modules, entries, rejected, entry_deadline_seconds, effects } => {
                let setup = duration(entry_deadline_seconds, "load deadline").and_then(|deadline| {
                    let effects = RawValue::from_string(effects)
                        .map_err(|e| format!("the daemon's effect table is not JSON: {e}"))?;
                    Ok((deadline, effects))
                });
                self.load(modules, entries, rejected, setup);
            }
            DaemonToHost::Permit { entry, permissions } => {
                let state = self.state.lock().unwrap();
                if let Some(worker) = state.by_entry.get(&entry).and_then(|id| state.workers.get(id)) {
                    let _ = worker.inbox.send(Inbound::Permit(permissions));
                }
            }
            DaemonToHost::Invoke { invocation, rule, event, timeout_seconds } => {
                let checked = duration(timeout_seconds, "timeout").and_then(|timeout| {
                    let event = RawValue::from_string(event).map_err(|e| format!("the event is not JSON: {e}"))?;
                    Ok((timeout, event))
                });
                #[cfg(test)]
                if self.halt_before_dispatch.swap(false, Ordering::Relaxed) {
                    self.halt();
                }
                if let Some(reason) = self.dispatch(invocation, &rule, checked) {
                    self.send(HostToDaemon::InvocationDone { invocation, error: Some(HandlerError::new(reason)) });
                }
            }
            DaemonToHost::EffectResult { call, result } => {
                let mut state = self.state.lock().unwrap();
                let Some((id, local)) = state.calls.remove(&call) else { return };
                let message = match result {
                    EffectOutcome::Success { value } => match RawValue::from_string(value) {
                        Ok(value) => JsMessage::EffectSucceeded { local, value },
                        Err(e) => {
                            JsMessage::EffectFailed { local, message: format!("the effect's value is not JSON: {e}") }
                        }
                    },
                    EffectOutcome::Failure { message } => JsMessage::EffectFailed { local, message },
                };
                if let Some(worker) = state.workers.get(&id) {
                    let _ = worker.inbox.send(Inbound::Js(message));
                }
            }
        }
    }

    /// Sends `invocation` to the worker running `rule`, or says why not;
    /// once the host halted, nothing. `stop` halts on the caller's thread,
    /// so an invoke queued before it can arrive after: the daemon settles it
    /// on `terminated`, and a refusal would charge the rule. Decided under
    /// the lock `halt` takes, so no halt falls between the check and the
    /// routing.
    fn dispatch(
        &self,
        invocation: u64,
        rule: &str,
        checked: Result<(Duration, Box<RawValue>), String>,
    ) -> Option<String> {
        let mut state = self.state.lock().unwrap();
        if state.terminated {
            return None;
        }
        let (timeout, event) = match checked {
            Ok(checked) => checked,
            Err(reason) => return Some(reason),
        };
        let Some((id, name)) = state.by_rule.get(rule).cloned() else {
            return Some(format!("no rule {rule} is loaded"));
        };
        // The worker finds the handler by name, and hands the handler its
        // rule's id as the host formed it.
        let message = JsMessage::Invoke { invocation, rule: rule.to_owned(), name, event };
        // Recorded before the worker can see the message, so its
        // `begin_invocation` always finds it.
        state.dispatched.insert(invocation, (id, rule.to_owned(), timeout));
        let sent = state.workers.get(&id).is_some_and(|worker| worker.inbox.send(Inbound::Js(message)).is_ok());
        if sent {
            None
        } else {
            state.dispatched.remove(&invocation);
            Some(format!("no rule {rule} is loaded"))
        }
    }

    /// Starts a worker for each entry, given the load deadline and the
    /// effect table; without them, every entry fails with the reason.
    fn load(
        self: &Arc<Self>,
        modules: Vec<HostModule>,
        entries: Vec<HostEntry>,
        rejected: HashMap<String, String>,
        setup: Result<(Duration, Box<RawValue>), String>,
    ) {
        let rules = Arc::new(RuleModules {
            modules: modules.into_iter().map(|module| (module.id, module.code)).collect(),
            rejected,
        });
        let mut spawned = Vec::new();
        {
            let mut state = self.state.lock().unwrap();
            if state.terminated {
                return;
            }
            if !matches!(state.load, Load::NotRequested) {
                drop(state);
                self.send(HostToDaemon::Log {
                    rule: None,
                    level: HostLogLevel::Error,
                    message: "a host loads one rule set; ignored a second load".into(),
                });
                return;
            }
            let modules = entries.iter().map(|entry| entry.module.clone()).collect();
            state.load = Load::Pending(PendingLoad { entries: modules, results: HashMap::new() });
            let (deadline, effects) = match setup {
                Ok(setup) => setup,
                Err(reason) => {
                    for HostEntry { module, .. } in entries {
                        let error = Some(HandlerError::new(reason.clone()));
                        record(&mut state, EntryResult { entry: module, rules: vec![], error });
                    }
                    drop(state);
                    self.finish_load_if_complete();
                    return;
                }
            };
            for HostEntry { module: entry, file } in entries {
                let id = self.next_worker.fetch_add(1, Ordering::Relaxed);
                let (inbox, receiver) = unbounded_channel();
                let control = Arc::new(WorkerControl::default());
                let url = module_specifier(&entry).to_string();
                let _ = inbox.send(Inbound::Js(JsMessage::Load { file: file.clone(), url, effects: effects.clone() }));
                self.watchdog.add_worker(id, file.clone(), deadline, Instant::now());
                state.workers.insert(
                    id,
                    Worker {
                        entry: entry.clone(),
                        file: file.clone(),
                        inbox,
                        control: control.clone(),
                        loading: true,
                        out_of_memory: None,
                    },
                );
                state.by_entry.insert(entry.clone(), id);
                spawned.push((WorkerSpec { id, entry, file, rules: rules.clone() }, receiver, control));
            }
        }
        for (spec, receiver, control) in spawned {
            worker::spawn(spec, receiver, control, self.clone());
        }
        self.finish_load_if_complete();
    }

    /// A worker's top-level code finished, or failed.
    pub(crate) fn worker_loaded(&self, id: WorkerId, result: Result<Vec<serde_json::Value>, HandlerError>) {
        {
            let mut state = self.state.lock().unwrap();
            let Some(worker) = state.workers.get_mut(&id) else { return };
            if !worker.loading {
                return;
            }
            worker.loading = false;
            let (entry, file) = (worker.entry.clone(), worker.file.clone());
            match result.and_then(|rules| definitions(&entry, &file, &rules)) {
                Ok((names, rules)) => {
                    // Under the host's lock: the watchdog may have dropped
                    // the file's clock for a load deadline that passed just
                    // now, and only here is it settled that the file stays
                    // (`fail_load` finds it loaded) and must be watched.
                    self.watchdog.loaded(id, &file, Instant::now());
                    for (rule, name) in names {
                        state.by_rule.insert(rule, (id, name));
                    }
                    record(&mut state, EntryResult { entry, rules, error: None });
                }
                Err(error) => {
                    // A file that failed to load runs nothing more.
                    let worker = state.workers.remove(&id);
                    state.by_entry.remove(&entry);
                    record(&mut state, EntryResult { entry, rules: vec![], error: Some(error) });
                    drop(state);
                    self.watchdog.remove_worker(id);
                    if let Some(worker) = worker {
                        worker.control.stop();
                    }
                }
            }
        }
        self.finish_load_if_complete();
    }

    /// Fails a file that is still loading: it is stopped and runs nothing.
    fn fail_load(&self, id: WorkerId, reason: String) {
        let reason = worker::cut(reason);
        let worker = {
            let mut state = self.state.lock().unwrap();
            let Some(worker) = state.workers.get(&id) else { return };
            if !worker.loading {
                return;
            }
            let worker = state.workers.remove(&id).expect("present");
            let entry = worker.entry.clone();
            state.by_entry.remove(&entry);
            record(&mut state, EntryResult { entry, rules: vec![], error: Some(HandlerError::new(reason)) });
            worker
        };
        self.watchdog.remove_worker(id);
        worker.control.stop();
        self.finish_load_if_complete();
    }

    fn finish_load_if_complete(&self) {
        let results = {
            let mut state = self.state.lock().unwrap();
            let complete = matches!(
                &state.load,
                Load::Pending(load) if load.entries.iter().all(|entry| load.results.contains_key(entry))
            );
            if !complete {
                return;
            }
            let Load::Pending(mut load) = std::mem::replace(&mut state.load, Load::Finished) else { return };
            load.entries.iter().map(|entry| load.results.remove(entry).expect("complete")).collect()
        };
        self.send(HostToDaemon::Loaded { results });
    }

    /// A log line from a worker, kept under `rule` only when that is one of
    /// the worker's own rules, and otherwise under its file: as with effects,
    /// the id is whatever rule code passed if it reached the op.
    pub(crate) fn log(&self, id: WorkerId, rule: Option<String>, level: HostLogLevel, message: String) {
        let rule = {
            let state = self.state.lock().unwrap();
            match rule {
                Some(rule) if state.by_rule.get(&rule).is_some_and(|(owner, _)| *owner == id) => Some(rule),
                // A worker's own voice (`rule: None`) is the file's too: only
                // the host speaks for no file.
                _ => match state.workers.get(&id) {
                    Some(worker) => Some(worker.file.clone()),
                    None => return,
                },
            }
        };
        self.send(HostToDaemon::Log { rule, level, message });
    }

    /// A worker acts only for its own file's rules; the daemon then holds
    /// the effect to that rule's grants and running invocation. A request
    /// naming another file's rule is refused to the worker, not forwarded.
    pub(crate) fn effect(&self, id: WorkerId, local: u64, invocation: u64, rule: String, request: String) {
        let call = {
            let mut state = self.state.lock().unwrap();
            if state.by_rule.get(&rule).is_none_or(|(owner, _)| *owner != id) {
                if let Some(worker) = state.workers.get(&id) {
                    let message = format!("{rule} is not a rule of this file");
                    let _ = worker.inbox.send(Inbound::Js(JsMessage::EffectFailed { local, message }));
                }
                return;
            }
            let call = self.next_call.fetch_add(1, Ordering::Relaxed);
            state.calls.insert(call, (id, local));
            call
        };
        self.send(HostToDaemon::Effect { call, invocation, rule, request });
    }

    /// A handler is starting. Its timeout is the one the daemon sent, never
    /// one rule code supplies. Beginning an invocation the host did not send
    /// to this worker can only be rule code reaching the host's ops, so the
    /// host stops.
    pub(crate) fn begin_invocation(&self, id: WorkerId, invocation: u64, rule: String) {
        let (file, timeout) = {
            let mut state = self.state.lock().unwrap();
            // A worker still finishing its turn while the host halts finds
            // nothing dispatched; that is the halt, not a violation.
            let Some(file) = state.workers.get(&id).map(|worker| worker.file.clone()) else { return };
            // Only an entry this worker was sent is consumed, so another
            // file cannot spend it.
            let matches = state
                .dispatched
                .get(&invocation)
                .is_some_and(|(worker, expected, _)| *worker == id && *expected == rule);
            let timeout =
                if matches { state.dispatched.remove(&invocation).map(|(_, _, timeout)| timeout) } else { None };
            (file, timeout)
        };
        let Some(timeout) = timeout else {
            // `rule` is whatever the code passed, so it stays out of the
            // reason.
            self.fault(file, Holder::default(), FaultKind::Failed, "began an invocation it was not sent".into());
            return;
        };
        self.watchdog.invocation_began(id, invocation, rule, timeout, Instant::now());
        self.send(HostToDaemon::Started { invocation });
    }

    /// A handler settled. Only the worker running the invocation may say so;
    /// an abandoned (timed-out) invocation's late completion is not
    /// reported, since the daemon already counted it.
    pub(crate) fn invocation_done(&self, id: WorkerId, invocation: u64, error: Option<HandlerError>) {
        // Settled without beginning (the file has no handler for the rule):
        // still this worker's to report, so the daemon is not left waiting.
        let unbegun = {
            let mut state = self.state.lock().unwrap();
            let owned = state.dispatched.get(&invocation).is_some_and(|(worker, _, _)| *worker == id);
            if owned {
                state.dispatched.remove(&invocation);
            }
            owned
        };
        if unbegun || self.watchdog.finished(id, invocation, Instant::now()) {
            self.send(HostToDaemon::InvocationDone { invocation, error });
        }
    }

    /// Called on the worker's thread while V8 is out of heap. The heap is
    /// the file's, so the fault is too; whoever holds the thread now made
    /// only the last allocation, and is named for diagnosis alone. That is
    /// no longer known once the worker has unwound.
    pub(crate) fn worker_out_of_memory(&self, id: WorkerId) {
        let holder = self.watchdog.holder(id);
        if let Some(worker) = self.state.lock().unwrap().workers.get_mut(&id) {
            worker.out_of_memory.get_or_insert(holder);
        }
    }

    /// A worker's thread ended without the host stopping it. `error` may be
    /// rule code's own text (an uncaught error that ended the event loop),
    /// so `fault` and `fail_load` bound it.
    pub(crate) fn worker_exited(&self, id: WorkerId, error: String) {
        let (loading, file, kind, error) = {
            let state = self.state.lock().unwrap();
            let Some(worker) = state.workers.get(&id) else { return };
            let (kind, error) = match &worker.out_of_memory {
                Some(Holder { rule: Some(rule), .. }) => {
                    (FaultKind::OutOfMemory, format!("{} (while {rule} ran)", worker::heap_exhausted()))
                }
                Some(_) => (FaultKind::OutOfMemory, worker::heap_exhausted()),
                None => (FaultKind::Failed, format!("stopped: {error}")),
            };
            (worker.loading, worker.file.clone(), kind, error)
        };
        if loading {
            self.fail_load(id, error);
        } else {
            self.fault(file, Holder::default(), kind, error);
        }
    }

    fn act(&self, finding: Finding) {
        match finding {
            Finding::InvocationTimedOut(invocation) => self.send(HostToDaemon::InvocationTimedOut { invocation }),
            Finding::LoadOverran { worker, deadline } => {
                self.fail_load(worker, format!("top-level code did not finish within {} s", deadline.as_secs_f64()));
            }
            Finding::Stuck { worker: _, file, holder, reason } => self.fault(file, holder, FaultKind::Overran, reason),
        }
    }

    /// A rule file's code ended the host: the daemon hears who, then the
    /// host stops. Only the first fault is reported; later ones are
    /// consequences of the halt, or race it.
    fn fault(&self, file: String, holder: Holder, kind: FaultKind, reason: String) {
        if !self.halt() {
            return;
        }
        let reason = worker::cut(reason);
        let ended = format!("{} {reason}", holder.rule.as_deref().unwrap_or(&file));
        self.send(HostToDaemon::Fault { file, rule: holder.rule, invocation: holder.invocation, kind, reason });
        self.close(&ended);
    }

    /// Stops every worker; nothing runs or is routed any more. Returns
    /// whether this call did it.
    fn halt(&self) -> bool {
        let workers: Vec<Arc<WorkerControl>> = {
            let mut state = self.state.lock().unwrap();
            if state.terminated {
                return false;
            }
            state.terminated = true;
            state.by_rule.clear();
            state.by_entry.clear();
            state.calls.clear();
            state.dispatched.clear();
            state.workers.drain().map(|(_, worker)| worker.control).collect()
        };
        for control in workers {
            control.stop();
        }
        true
    }

    /// Stops every worker and tells the daemon, after everything sent so
    /// far. Only the first reason is reported.
    fn shutdown(&self, reason: &str) {
        self.halt();
        self.close(reason);
    }

    /// Tells the daemon the host stopped, after everything sent so far.
    fn close(&self, reason: &str) {
        let sender = self.outbound.lock().unwrap().take();
        if let Some(sender) = sender {
            let _ = sender.send(Outbound::Terminated(reason.to_owned()));
        }
    }
}

/// A rule's id: its file, `#`, its name. The daemon forms the same id from
/// the definitions this file reported (`RuleID` in `MeerkatKit`), and invokes
/// by it. Neither part holds a `#`: the daemon loads no entry file whose
/// name does, and fails a rule whose name does, or whose name is longer than
/// `MAXIMUM_RULE_NAME`, which is not routed here either; so one id is one
/// rule of one file, and fits beside any text the host sends.
fn rule_id(file: &str, name: &str) -> String {
    format!("{file}#{name}")
}

/// Each rule's id and name, to route invocations by.
type Routes = Vec<(String, String)>;

/// The file's rules as the daemon gets them, each definition back to JSON
/// text for it to decode, with each rule's id and name to route by. A file
/// whose result would not fit in one message fails alone.
fn definitions(entry: &str, file: &str, rules: &[serde_json::Value]) -> Result<(Routes, Vec<String>), HandlerError> {
    let texts: Vec<String> = rules.iter().map(ToString::to_string).collect();
    definitions_fit(entry.len() + texts.iter().map(String::len).sum::<usize>())?;
    let names = rules
        .iter()
        .filter_map(|rule| rule.get("name").and_then(|name| name.as_str()))
        .filter(|name| !name.contains('#') && name.len() <= MAXIMUM_RULE_NAME)
        .map(|name| (rule_id(file, name), name.to_owned()))
        .collect();
    Ok((names, texts))
}

/// Whether a file's rule definitions, `bytes` of them, fit in the message
/// that reports them; a worker also refuses longer text unread (worker.rs).
pub(crate) fn definitions_fit(bytes: usize) -> Result<(), HandlerError> {
    if bytes > MAXIMUM_MESSAGE_TEXT {
        return Err(HandlerError::new(format!(
            "its rule definitions take {bytes} bytes; at most {MAXIMUM_MESSAGE_TEXT} fit in one message"
        )));
    }
    Ok(())
}

fn duration(seconds: f64, what: &str) -> Result<Duration, String> {
    Duration::try_from_secs_f64(seconds).map_err(|_| format!("the daemon sent a {what} of {seconds} s"))
}

fn record(state: &mut State, result: EntryResult) {
    if let Load::Pending(load) = &mut state.load {
        load.results.insert(result.entry.clone(), result);
    }
}
