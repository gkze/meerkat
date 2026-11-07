//! meerkatd's rule-handler runtime: Deno, embedded in the daemon's process
//! and exported to Swift through UniFFI (`Sources/meerkat-runtime/bindgen` generates the
//! bindings in `Sources/meerkat-runtime`).
//!
//! The daemon starts a host with a delegate, sends it `DaemonToHost`
//! messages and receives `HostToDaemon` messages on the delegate. User code
//! stays on the far side of that boundary: what it produces reaches the
//! daemon as JSON text the daemon decodes, and every effect it asks for is
//! checked by the daemon.

mod host;
mod loader;
mod protected;
mod protocol;
mod watchdog;
mod worker;

#[cfg(test)]
mod tests;

use std::sync::Arc;

pub use protocol::{
    DaemonToHost, EffectOutcome, EntryResult, FaultKind, FilePermissions, HandlerError, HostLogLevel, HostModule,
    HostToDaemon,
};

uniffi::setup_scaffolding!();

/// Where a host delivers what it sends: implemented by the daemon.
#[uniffi::export(with_foreign)]
pub trait HostDelegate: Send + Sync {
    /// One message. Called on the host's delivery thread, one call at a
    /// time and in order; blocking here holds back the workers sending.
    fn receive(&self, message: HostToDaemon);
    /// Called once, after the last `receive`, with why the host stopped. No
    /// call follows it.
    fn terminated(&self, reason: String);
}

impl host::Delivery for Arc<dyn HostDelegate> {
    fn message(&mut self, message: HostToDaemon) {
        self.receive(message);
    }

    fn terminated(&mut self, reason: &str) {
        HostDelegate::terminated(self.as_ref(), reason.to_owned());
    }
}

/// One handler host. Its methods never block: they queue for the host's
/// control thread. Releasing the last reference stops the host; the
/// delegate can still be called until `terminated`.
#[derive(uniffi::Object)]
pub struct RuntimeHost(host::Host);

#[uniffi::export]
impl RuntimeHost {
    /// Starts a host; its first message is `ready`.
    #[uniffi::constructor]
    pub fn start(delegate: Arc<dyn HostDelegate>) -> Arc<Self> {
        Arc::new(RuntimeHost(host::Host::start(delegate)))
    }

    /// Ignored once the host stopped.
    pub fn send(&self, message: DaemonToHost) {
        self.0.receive(message);
    }

    /// Interrupts every worker at once; `terminated` follows the messages
    /// already sent. Safe to call more than once.
    pub fn stop(&self, reason: String) {
        self.0.stop(&reason);
    }
}

/// Work the daemon does for a rule on a path it checks first, such as moving
/// it to the Trash: implemented by the daemon.
#[uniffi::export(with_foreign)]
pub trait PathWork: Send + Sync {
    fn run(&self);
}

/// Runs `work` on the calling thread while no rule's code renames anything,
/// or is between a file system call's check and its end (protected.rs,
/// `NAMESPACE`), so a path `work` checks still leads where it did when
/// `work` acts on it. Blocks while a rule's call is under way: call it off
/// any thread that must not wait.
#[uniffi::export]
pub fn hold_rule_renames(work: Arc<dyn PathWork>) {
    protected::holding_renames(|| work.run());
}

/// `MAXIMUM_MESSAGE_TEXT`, for the daemon's own check of what a host sends.
#[uniffi::export]
#[must_use]
pub fn maximum_message_text_bytes() -> u64 {
    protocol::MAXIMUM_MESSAGE_TEXT as u64
}

/// The TypeScript declarations of the globals rule code runs with (composed
/// by build.rs).
#[uniffi::export]
#[must_use]
pub fn runtime_declarations() -> String {
    DECLARATIONS.to_owned()
}

const DECLARATIONS: &str = include_str!(concat!(env!("OUT_DIR"), "/deno.d.ts"));
