//! The messages between the daemon and the runtime.
//!
//! These types are the protocol's single definition: UniFFI exports them,
//! and `Sources/meerkat-runtime/bindgen` generates their Swift side
//! (`Sources/meerkat-runtime/MeerkatRuntimeBindings`), which the daemon uses as is.
//! Field names are snake case here and lower camel case in Swift.
//!
//! What JavaScript produces or consumes (an event, an effect request or its
//! value, a rule's definition) stays JSON text: the runtime hands it to and
//! takes it from rule code without interpreting it, and the daemon decodes
//! and checks it, because it comes from user code.

use std::collections::HashMap;

use serde::Deserialize;

/// A compiled ES module, by its path relative to the rules directory without
/// the extension (`util`, `lib/paths`).
#[derive(Debug, uniffi::Record)]
pub struct HostModule {
    pub id: String,
    pub code: String,
}

/// An entry module and its file's name, which the daemon gives it (the
/// module plus `.ts`): the host calls the file that in every `Fault`, every
/// `Log` and the first part of each of its rules' ids, so the daemon's name
/// for a file is the only one.
#[derive(Debug, Clone, uniffi::Record)]
pub struct HostEntry {
    pub module: String,
    pub file: String,
}

#[derive(Debug, uniffi::Enum)]
pub enum DaemonToHost {
    /// Load the rule set: each entry in a worker of its own. `rejected` maps
    /// module ids to the reason they may not be imported. An entry's
    /// top-level code has `entry_deadline_seconds` to finish; one that does
    /// not fails alone. A host loads once.
    Load {
        modules: Vec<HostModule>,
        entries: Vec<HostEntry>,
        rejected: HashMap<String, String>,
        entry_deadline_seconds: f64,
        /// The daemon's effect table, as JSON: each effect's wire name, its
        /// place on the handler context, how its arguments become request
        /// fields and how its result comes back. The runtime builds every
        /// handler's context from it, so the daemon's effect catalog is the
        /// one definition of what a context offers.
        effects: String,
    },
    /// What one loaded entry's code may do through Deno's own APIs, from
    /// now on. Until the first permit, nothing.
    Permit { entry: String, permissions: FilePermissions },
    /// Run one rule's handler on `event`, an event envelope as JSON. The
    /// host enforces `timeout_seconds` from the moment the handler starts,
    /// not from when the message was sent.
    ///
    /// `rule` is the rule's id: its file (`HostEntry.file`), `#`, its
    /// name. The daemon forms it from the definition (`RuleDefinition.id`),
    /// and the host from the definitions the file reported (host.rs,
    /// `rule_id`), which it hands the rule's code.
    Invoke { invocation: u64, rule: String, event: String, timeout_seconds: f64 },
    /// The outcome of an effect the host requested.
    EffectResult { call: u64, result: EffectOutcome },
}

/// What one rule file's code may do through Deno's own APIs: absolute path
/// prefixes. A deny wins over a grant; an empty list grants nothing.
#[derive(Debug, Clone, Default, PartialEq, uniffi::Record)]
pub struct FilePermissions {
    #[uniffi(default)]
    pub read: Vec<String>,
    #[uniffi(default)]
    pub write: Vec<String>,
    #[uniffi(default)]
    pub deny_read: Vec<String>,
    #[uniffi(default)]
    pub deny_write: Vec<String>,
}

#[derive(Debug, uniffi::Enum)]
pub enum EffectOutcome {
    /// The effect's value, as JSON.
    Success {
        value: String,
    },
    Failure {
        message: String,
    },
}

/// Most text one message from the host may carry: the UTF-8 bytes of its
/// strings, counted as the daemon counts them (`HostToDaemon.limitedBytes` in
/// `HandlerHost`), and for `Loaded` per entry. Rule code cannot make the host
/// send more: each op cuts or refuses what would pass it (worker.rs), a file
/// whose definitions would fails alone and every fault or load failure's
/// reason is cut (host.rs), and the rule id a log or fault carries beside
/// that text is a file's name, which the file system bounds, and a name of
/// at most `MAXIMUM_RULE_NAME`. The daemon stops a host that sends more
/// anyway.
pub const MAXIMUM_MESSAGE_TEXT: usize = 4 << 20;

/// Longest rule name, in UTF-8 bytes. A rule whose name is longer is not
/// routed (host.rs, `definitions`), and the daemon fails it
/// (`RuleID.refusal(name:)` in `MeerkatKit`, which holds the same number).
pub const MAXIMUM_RULE_NAME: usize = 256;

/// Longest log message, error message or stack, log label and fault reason
/// the host sends, in bytes; longer ones are cut to it (worker.rs, `cut`).
/// Well within `MAXIMUM_MESSAGE_TEXT`, so what rule code logs or throws
/// never stops the host. The daemon holds its own rule log lines to it too.
pub const MAXIMUM_TEXT: usize = 64 << 10;

#[derive(Debug, uniffi::Enum)]
pub enum HostToDaemon {
    /// The host is up and waiting for `load`.
    Ready,
    /// The outcome of `load`, one entry per entry module.
    Loaded {
        results: Vec<EntryResult>,
    },
    /// The handler began running (it may have waited behind others).
    Started {
        invocation: u64,
    },
    InvocationDone {
        invocation: u64,
        error: Option<HandlerError>,
    },
    /// The handler's promise did not settle within its timeout while the
    /// JavaScript thread stayed responsive. The invocation is abandoned; the
    /// host keeps running.
    InvocationTimedOut {
        invocation: u64,
    },
    /// A rule file's code ended the host, which is stopping. Names the
    /// file, and for an overrun the rule and invocation when that rule's
    /// handler was running its own code (after an `await`, or in a timer,
    /// the runtime knows only the file). Only an overrun names them: running
    /// out of heap, or a worker failing, is the file's alone. `reason`
    /// follows the name: "held the JavaScript thread for 5.1 s". The host's
    /// `terminated` reason that follows is that sentence whole: the rule's id
    /// or the file, then `reason`.
    Fault {
        file: String,
        rule: Option<String>,
        invocation: Option<u64>,
        kind: FaultKind,
        reason: String,
    },
    /// A handler asked for an effect, `request` as JSON. `rule` is the rule
    /// whose handler made the call; the daemon checks it against that rule's
    /// grants.
    Effect {
        call: u64,
        invocation: u64,
        rule: String,
        request: String,
    },
    Log {
        rule: Option<String>,
        level: HostLogLevel,
        message: String,
    },
}

/// How a rule file's code ended the host.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FaultKind {
    /// It held the JavaScript thread past its budget, or kept it busy past
    /// the file's share (watchdog.rs).
    Overran,
    /// It passed the file's heap limit.
    OutOfMemory,
    /// Its worker failed otherwise: its event loop ended, Rust code on the
    /// worker's thread panicked where it is caught (worker.rs, `spawn`), or
    /// its code did what only code reaching the host's ops can.
    Failed,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct EntryResult {
    /// The entry's module, as `HostEntry.module` named it.
    pub entry: String,
    /// Each rule's definition with `handle` removed, as the author wrote it,
    /// as JSON.
    pub rules: Vec<String>,
    pub error: Option<HandlerError>,
}

/// Also what runtime.js reports a failure as, so it decodes from that JSON.
#[derive(Debug, Clone, PartialEq, Deserialize, uniffi::Record)]
pub struct HandlerError {
    pub message: String,
    #[serde(default)]
    #[uniffi(default)]
    pub stack: Option<String>,
}

impl HandlerError {
    pub fn new(message: impl Into<String>) -> Self {
        HandlerError { message: message.into(), stack: None }
    }
}

/// `HostLogLevel` rather than `LogLevel`: the daemon's client protocol has
/// its own `LogLevel`, which the app uses without linking the runtime.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Enum)]
pub enum HostLogLevel {
    Debug,
    Info,
    Warn,
    Error,
}

impl HostLogLevel {
    /// A level as runtime.js names it. It names only these four, and maps
    /// Deno's console levels above warn to "error"; anything else is code
    /// reaching the op directly, and is kept as an error too.
    #[must_use]
    pub fn parse(text: &str) -> HostLogLevel {
        match text {
            "debug" => HostLogLevel::Debug,
            "info" => HostLogLevel::Info,
            "warn" => HostLogLevel::Warn,
            _ => HostLogLevel::Error,
        }
    }
}
