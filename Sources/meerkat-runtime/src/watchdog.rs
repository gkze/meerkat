//! Deadlines for rule code, enforced where it is known who holds each
//! worker's JavaScript thread.
//!
//! Each rule file runs on a worker thread of its own. While the thread runs
//! JavaScript it has an *activity*: the handler a rule's invocation started
//! (owned by that rule and invocation, with the invocation's timeout as its
//! budget), or anything else the file's event loop runs, such as timers and
//! the continuations of handlers after an `await` (owned by the file, which
//! may run for `TIMER_BUDGET`, or until the last deadline of an invocation of
//! that file in flight, whichever is later; once the last one settles, for
//! `TIMER_BUDGET` from then).
//!
//! - A file still loading has its load deadline for everything it does,
//!   synchronous or not; overrunning it fails that file alone.
//! - An invocation whose promise has not settled by its timeout, while its
//!   own handler is not running, is reported timed out and abandoned.
//! - Any other activity that overruns its budget is reported `Stuck`; the
//!   host then stops, and the daemon restarts it.
//! - A file whose own work, while none of its invocations is in flight,
//!   keeps its thread busy for more than `DUTY_LIMIT` of a `DUTY_WINDOW` is
//!   reported `Stuck` too: short timer callbacks one after another would
//!   otherwise hold a core for good, as would the continuations of handlers
//!   already abandoned.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub type WorkerId = u64;

/// Budget for JavaScript a file runs outside any handler invocation.
pub const TIMER_BUDGET: Duration = Duration::from_secs(1);
/// How much of each `DUTY_WINDOW` a file's own work may use while none of
/// its invocations is in flight.
pub const DUTY_LIMIT: Duration = Duration::from_secs(5);
pub const DUTY_WINDOW: Duration = Duration::from_secs(10);

#[derive(Debug, Clone, PartialEq)]
pub enum Finding {
    InvocationTimedOut(u64),
    /// A file's top-level code did not finish within its load deadline.
    LoadOverran {
        worker: WorkerId,
        deadline: Duration,
    },
    /// `reason` follows the holder's name: "held the JavaScript thread for
    /// 1.2 s".
    Stuck {
        worker: WorkerId,
        file: String,
        holder: Holder,
        reason: String,
    },
}

/// Whose code holds a worker's thread, beyond its file: a rule's handler,
/// while it runs its own synchronous part. Empty for the file's own work.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Holder {
    pub rule: Option<String>,
    pub invocation: Option<u64>,
}

struct Activity {
    holder: Holder,
    began: Instant,
    /// `None` for the file's own work, whose deadline depends on what is in
    /// flight when it is checked.
    budget: Option<Duration>,
    /// From when the file's own work counts toward its duty: when it began,
    /// or when the file's last invocation in flight ended during it. Work
    /// before that was the invocations'.
    idle_since: Instant,
}

impl Activity {
    fn file(now: Instant) -> Self {
        Activity { holder: Holder::default(), began: now, budget: None, idle_since: now }
    }
}

struct Clock {
    file: String,
    /// While the file loads: when it started and its deadline.
    loading: Option<(Instant, Duration)>,
    current: Option<Activity>,
    duty: Duty,
}

impl Clock {
    fn new(file: String, loading: Option<(Instant, Duration)>, now: Instant) -> Self {
        Clock { file, loading, current: None, duty: Duty { window: now, busy: Duration::ZERO } }
    }
}

/// The file's own work while none of its invocations is in flight, in the
/// current window. Tumbling windows: a file over the limit is over it in some
/// window, give or take one window's worth of lag.
struct Duty {
    window: Instant,
    busy: Duration,
}

impl Duty {
    fn busy(&self, now: Instant) -> Duration {
        if now.duration_since(self.window) >= DUTY_WINDOW { Duration::ZERO } else { self.busy }
    }

    fn add(&mut self, held: Duration, now: Instant) {
        if now.duration_since(self.window) >= DUTY_WINDOW {
            self.window = now;
            self.busy = Duration::ZERO;
        }
        self.busy += held;
    }
}

struct Flight {
    worker: WorkerId,
    started: Instant,
    timeout: Duration,
}

#[derive(Default)]
struct State {
    clocks: HashMap<WorkerId, Clock>,
    flights: HashMap<u64, Flight>,
    /// Set once a `Stuck` was reported: the host is stopping.
    fired: bool,
}

impl State {
    fn in_flight(&self, worker: WorkerId) -> bool {
        self.flights.values().any(|flight| flight.worker == worker)
    }

    /// Ends the worker's current activity and starts `next`, charging the
    /// one that ended to the file's duty for the part of it with nothing in
    /// flight.
    fn set(&mut self, worker: WorkerId, next: Option<Activity>, now: Instant) {
        let idle = !self.in_flight(worker);
        let Some(clock) = self.clocks.get_mut(&worker) else { return };
        if let Some(ended) = clock.current.take()
            && ended.budget.is_none()
            && idle
            && clock.loading.is_none()
        {
            clock.duty.add(now.duration_since(ended.idle_since), now);
        }
        clock.current = next;
    }

    /// An invocation of `worker` ended. When it was the last in flight, the
    /// file's own work from now on is the file's, not the invocation's.
    fn landed(&mut self, worker: WorkerId, now: Instant) {
        if self.in_flight(worker) {
            return;
        }
        if let Some(activity) = self.clocks.get_mut(&worker).and_then(|clock| clock.current.as_mut())
            && activity.budget.is_none()
        {
            activity.idle_since = now;
        }
    }
}

#[derive(Default)]
pub struct Watchdog {
    state: Mutex<State>,
}

impl Watchdog {
    pub fn add_worker(&self, worker: WorkerId, file: String, load_deadline: Duration, now: Instant) {
        let clock = Clock::new(file, Some((now, load_deadline)), now);
        self.state.lock().unwrap().clocks.insert(worker, clock);
    }

    /// The file finished loading. Its clock is kept, or made again when the
    /// load deadline passed meanwhile: the host decides under its own lock
    /// whether the load counts (host.rs), and a worker it keeps must never
    /// run unwatched.
    pub fn loaded(&self, worker: WorkerId, file: &str, now: Instant) {
        let mut state = self.state.lock().unwrap();
        state.clocks.entry(worker).or_insert_with(|| Clock::new(file.to_owned(), None, now)).loading = None;
    }

    pub fn remove_worker(&self, worker: WorkerId) {
        let mut state = self.state.lock().unwrap();
        state.clocks.remove(&worker);
        state.flights.retain(|_, flight| flight.worker != worker);
    }

    /// The worker's event loop is about to run whatever is ready.
    pub fn poll_began(&self, worker: WorkerId, now: Instant) {
        self.state.lock().unwrap().set(worker, Some(Activity::file(now)), now);
    }

    /// The worker's event loop is waiting: no JavaScript runs.
    pub fn poll_ended(&self, worker: WorkerId, now: Instant) {
        self.state.lock().unwrap().set(worker, None, now);
    }

    /// A rule's handler is starting; its timeout runs from here.
    pub fn invocation_began(&self, worker: WorkerId, invocation: u64, rule: String, timeout: Duration, now: Instant) {
        let mut state = self.state.lock().unwrap();
        let holder = Holder { rule: Some(rule), invocation: Some(invocation) };
        let activity = Activity { holder, began: now, budget: Some(timeout), idle_since: now };
        state.set(worker, Some(activity), now);
        state.flights.insert(invocation, Flight { worker, started: now, timeout });
    }

    /// The handler returned (its promise may still be pending); whatever runs
    /// next on the thread is the file's.
    pub fn segment_ended(&self, worker: WorkerId, now: Instant) {
        self.state.lock().unwrap().set(worker, Some(Activity::file(now)), now);
    }

    /// Returns false when the invocation was already abandoned, so its late
    /// completion is not reported, and when it is not `worker`'s.
    pub fn finished(&self, worker: WorkerId, invocation: u64, now: Instant) -> bool {
        let mut state = self.state.lock().unwrap();
        if state.flights.get(&invocation).is_none_or(|flight| flight.worker != worker) {
            return false;
        }
        state.flights.remove(&invocation);
        state.landed(worker, now);
        true
    }

    /// Who holds the worker's thread right now: what a fault on that thread
    /// is charged to.
    pub fn holder(&self, worker: WorkerId) -> Holder {
        let state = self.state.lock().unwrap();
        state
            .clocks
            .get(&worker)
            .and_then(|clock| clock.current.as_ref())
            .map(|activity| activity.holder.clone())
            .unwrap_or_default()
    }

    pub fn check(&self, now: Instant) -> Vec<Finding> {
        let mut state = self.state.lock().unwrap();
        if state.fired {
            return Vec::new();
        }
        let mut findings = Vec::new();

        let mut workers: Vec<WorkerId> = state.clocks.keys().copied().collect();
        workers.sort_unstable();
        for worker in workers {
            let clock = &state.clocks[&worker];
            if let Some((started, deadline)) = clock.loading {
                if now.duration_since(started) > deadline {
                    // Reported once; the host retires the worker.
                    state.clocks.remove(&worker);
                    findings.push(Finding::LoadOverran { worker, deadline });
                }
                continue;
            }
            if let Some(stuck) = stuck(&state, worker, clock, now) {
                state.fired = true;
                return vec![stuck];
            }
        }

        // An invocation whose own handler holds the thread is judged by its
        // activity budget above, not here.
        let running: Vec<u64> = state
            .clocks
            .values()
            .filter_map(|clock| clock.current.as_ref().and_then(|activity| activity.holder.invocation))
            .collect();
        let mut expired: Vec<u64> = state
            .flights
            .iter()
            .filter(|(id, flight)| now.duration_since(flight.started) > flight.timeout && !running.contains(id))
            .map(|(id, _)| *id)
            .collect();
        expired.sort_unstable();
        for id in expired {
            if let Some(flight) = state.flights.remove(&id) {
                state.landed(flight.worker, now);
            }
            findings.push(Finding::InvocationTimedOut(id));
        }
        findings
    }
}

/// Whether a running worker's thread is past its activity's budget, or its
/// file past its share of the thread.
fn stuck(state: &State, worker: WorkerId, clock: &Clock, now: Instant) -> Option<Finding> {
    let found = |holder, reason| Finding::Stuck { worker, file: clock.file.clone(), holder, reason };
    let idle = !state.in_flight(worker);
    let mut busy = clock.duty.busy(now);
    if let Some(activity) = &clock.current {
        let deadline = match activity.budget {
            Some(budget) => activity.began + budget,
            None => file_deadline(&state.flights, worker, activity.idle_since),
        };
        if now > deadline {
            let held = now.duration_since(activity.began);
            let reason = format!("held the JavaScript thread for {:.1} s", held.as_secs_f64());
            return Some(found(activity.holder.clone(), reason));
        }
        if activity.budget.is_none() && idle {
            busy += now.duration_since(activity.idle_since);
        }
    }
    (idle && busy > DUTY_LIMIT).then(|| {
        let reason = format!(
            "kept the JavaScript thread busy for {:.1} s of {} s outside any handler",
            busy.as_secs_f64(),
            DUTY_WINDOW.as_secs()
        );
        found(Holder::default(), reason)
    })
}

/// A file's own work may run until the last deadline of its invocations in
/// flight (a handler's continuation is the file's work), and never for less
/// than `TIMER_BUDGET` from `idle_since`: when it began, or when the last
/// invocation in flight settled during it, so the rest of a poll in which a
/// long continuation settled its invocation is not already late. An instant,
/// not a span: what is left to an invocation shrinks as the work runs.
fn file_deadline(flights: &HashMap<u64, Flight>, worker: WorkerId, idle_since: Instant) -> Instant {
    flights
        .values()
        .filter(|flight| flight.worker == worker)
        .map(|flight| flight.started + flight.timeout)
        .fold(idle_since + TIMER_BUDGET, Instant::max)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SECOND: Duration = Duration::from_secs(1);
    /// `check` found nothing; compared with `assert_eq!` to print what it found.
    const NOTHING: [Finding; 0] = [];

    fn running(watchdog: &Watchdog, worker: WorkerId, now: Instant) {
        watchdog.add_worker(worker, format!("f{worker}.ts"), 5 * SECOND, now);
        watchdog.loaded(worker, &format!("f{worker}.ts"), now);
    }

    #[test]
    fn a_pending_promise_times_out_and_is_abandoned() {
        let watchdog = Watchdog::default();
        let t0 = Instant::now();
        running(&watchdog, 1, t0);
        watchdog.invocation_began(1, 7, "f1.ts#a".into(), 2 * SECOND, t0);
        watchdog.segment_ended(1, t0);
        watchdog.poll_ended(1, t0);
        assert_eq!(watchdog.check(t0 + SECOND), NOTHING);
        assert_eq!(watchdog.check(t0 + 3 * SECOND), [Finding::InvocationTimedOut(7)]);
        assert!(!watchdog.finished(1, 7, t0 + 3 * SECOND), "a late completion is not reported");
        assert!(watchdog.check(t0 + 4 * SECOND).is_empty(), "reported once");
    }

    #[test]
    fn a_handler_holding_the_thread_is_stuck_and_named() {
        let watchdog = Watchdog::default();
        let t0 = Instant::now();
        running(&watchdog, 1, t0);
        watchdog.invocation_began(1, 7, "f1.ts#a".into(), 2 * SECOND, t0);
        let findings = watchdog.check(t0 + 3 * SECOND);
        let [Finding::Stuck { worker: 1, holder, .. }] = findings.as_slice() else { panic!("{findings:?}") };
        assert_eq!(holder, &Holder { rule: Some("f1.ts#a".into()), invocation: Some(7) });
        assert!(watchdog.check(t0 + 4 * SECOND).is_empty(), "the host is already stopping");
    }

    #[test]
    fn a_files_own_work_has_the_timer_budget() {
        let watchdog = Watchdog::default();
        let t0 = Instant::now();
        running(&watchdog, 1, t0);
        watchdog.poll_began(1, t0);
        assert_eq!(watchdog.check(t0 + SECOND / 2), NOTHING);
        let findings = watchdog.check(t0 + 2 * SECOND);
        assert!(
            matches!(findings.as_slice(), [Finding::Stuck { holder: Holder { rule: None, invocation: None }, .. }]),
            "{findings:?}"
        );
    }

    #[test]
    fn a_continuation_may_use_what_is_left_of_its_invocation() {
        let watchdog = Watchdog::default();
        let t0 = Instant::now();
        running(&watchdog, 1, t0);
        watchdog.invocation_began(1, 7, "f1.ts#a".into(), 10 * SECOND, t0);
        watchdog.segment_ended(1, t0 + SECOND);
        // The invocation's deadline is t0 + 10: its continuation may run until
        // then, not only for half of what was left when it began.
        assert_eq!(watchdog.check(t0 + 4 * SECOND), NOTHING);
        assert_eq!(watchdog.check(t0 + SECOND * 99 / 10), NOTHING);
        let findings = watchdog.check(t0 + 12 * SECOND);
        assert!(
            matches!(findings.as_slice(), [Finding::Stuck { holder: Holder { rule: None, .. }, .. }]),
            "{findings:?}"
        );
    }

    #[test]
    fn a_files_own_work_has_a_share_of_its_thread() {
        let watchdog = Watchdog::default();
        let t0 = Instant::now();
        running(&watchdog, 1, t0);
        // Timer callbacks of 0.9 s, one a second: each within the timer
        // budget, together most of the thread.
        let mut now = t0;
        for callback in 0..6 {
            watchdog.poll_began(1, now);
            now += SECOND * 9 / 10;
            if callback < 5 {
                assert_eq!(watchdog.check(now), NOTHING, "callback {callback}");
            }
            watchdog.poll_ended(1, now);
            now += SECOND / 10;
        }
        let findings = watchdog.check(now);
        let [Finding::Stuck { worker: 1, holder: Holder { rule: None, invocation: None }, reason, .. }] =
            findings.as_slice()
        else {
            panic!("{findings:?}")
        };
        assert!(reason.starts_with("kept the JavaScript thread busy for 5.4 s"), "{reason}");
    }

    #[test]
    fn work_while_an_invocation_is_in_flight_is_the_invocations() {
        let watchdog = Watchdog::default();
        let t0 = Instant::now();
        running(&watchdog, 1, t0);
        watchdog.invocation_began(1, 7, "f1.ts#a".into(), 60 * SECOND, t0);
        watchdog.segment_ended(1, t0);
        watchdog.poll_ended(1, t0);
        let mut now = t0;
        for _ in 0..8 {
            watchdog.poll_began(1, now);
            now += SECOND * 9 / 10;
            watchdog.poll_ended(1, now);
            now += SECOND / 10;
        }
        assert_eq!(watchdog.check(now), NOTHING);
    }

    /// The usual end of a handler: its continuation settles its invocation
    /// within the poll it runs in. That poll's work before the settling was
    /// the invocation's, so it is not charged to the file's share.
    #[test]
    fn a_continuation_that_settles_its_invocation_is_not_charged_to_the_file() {
        let watchdog = Watchdog::default();
        let t0 = Instant::now();
        running(&watchdog, 1, t0);
        watchdog.poll_began(1, t0);
        watchdog.invocation_began(1, 7, "f1.ts#a".into(), 10 * SECOND, t0);
        watchdog.segment_ended(1, t0);
        watchdog.poll_ended(1, t0);
        // After an `await`, six seconds of work, then the handler returns.
        watchdog.poll_began(1, t0 + SECOND);
        assert_eq!(watchdog.check(t0 + 7 * SECOND), NOTHING);
        assert!(watchdog.finished(1, 7, t0 + 7 * SECOND));
        watchdog.poll_ended(1, t0 + 7 * SECOND);
        assert_eq!(watchdog.check(t0 + 7 * SECOND), NOTHING);
        // Work after the settling is the file's again.
        watchdog.poll_began(1, t0 + 8 * SECOND);
        watchdog.poll_ended(1, t0 + SECOND * 89 / 10);
        assert_eq!(watchdog.check(t0 + 9 * SECOND), NOTHING);
    }

    /// The rest of the poll in which a long continuation settles its
    /// invocation (nextTick, immediate and rejection work queued after it)
    /// has the timer budget from the settling, not from when the poll began.
    #[test]
    fn the_rest_of_a_poll_after_the_settling_has_the_timer_budget() {
        let watchdog = Watchdog::default();
        let t0 = Instant::now();
        running(&watchdog, 1, t0);
        watchdog.invocation_began(1, 7, "f1.ts#a".into(), 10 * SECOND, t0);
        watchdog.segment_ended(1, t0);
        watchdog.poll_ended(1, t0);
        watchdog.poll_began(1, t0 + SECOND);
        assert!(watchdog.finished(1, 7, t0 + 7 * SECOND));
        assert_eq!(watchdog.check(t0 + 7 * SECOND), NOTHING);
        assert_eq!(watchdog.check(t0 + SECOND * 75 / 10), NOTHING);
        let findings = watchdog.check(t0 + SECOND * 81 / 10);
        assert!(
            matches!(findings.as_slice(), [Finding::Stuck { holder: Holder { rule: None, .. }, .. }]),
            "{findings:?}"
        );
    }

    /// Work in the same poll after the last invocation settles is the file's,
    /// and the work before it is not: charging the whole poll, or none of it,
    /// each gets this wrong.
    #[test]
    fn work_after_the_last_invocation_settles_is_the_files() {
        let watchdog = Watchdog::default();
        let t0 = Instant::now();
        running(&watchdog, 1, t0);
        watchdog.invocation_began(1, 7, "f1.ts#a".into(), 60 * SECOND, t0);
        watchdog.segment_ended(1, t0);
        watchdog.poll_ended(1, t0);
        // Two seconds of the invocation's work, then 0.9 s of the file's.
        watchdog.poll_began(1, t0 + SECOND);
        assert!(watchdog.finished(1, 7, t0 + 3 * SECOND));
        let mut now = t0 + 3 * SECOND + SECOND * 9 / 10;
        watchdog.poll_ended(1, now);
        let poll = |now: &mut Instant| {
            *now += SECOND / 10;
            watchdog.poll_began(1, *now);
            *now += SECOND * 9 / 10;
            watchdog.poll_ended(1, *now);
        };
        // 4.5 s of the file's own: within its share. Charged from when the
        // poll began, it would be 6.5 s.
        for _ in 0..4 {
            poll(&mut now);
        }
        assert_eq!(watchdog.check(now), NOTHING);
        // 5.4 s: past it. Without the 0.9 s after the settling, 4.5 s.
        poll(&mut now);
        let findings = watchdog.check(now);
        assert!(matches!(findings.as_slice(), [Finding::Stuck { worker: 1, .. }]), "{findings:?}");
    }

    /// The host keeps a file that finished loading just as its deadline
    /// passed (it decides under its own lock); that file is still watched.
    #[test]
    fn a_file_kept_after_its_load_deadline_is_still_watched() {
        let watchdog = Watchdog::default();
        let t0 = Instant::now();
        watchdog.add_worker(1, "f1.ts".into(), 5 * SECOND, t0);
        assert_eq!(watchdog.check(t0 + 6 * SECOND), [Finding::LoadOverran { worker: 1, deadline: 5 * SECOND }]);
        watchdog.loaded(1, "f1.ts", t0 + 6 * SECOND);
        watchdog.poll_began(1, t0 + 6 * SECOND);
        let findings = watchdog.check(t0 + 8 * SECOND);
        assert!(matches!(findings.as_slice(), [Finding::Stuck { worker: 1, .. }]), "{findings:?}");
    }

    #[test]
    fn workers_are_judged_separately() {
        let watchdog = Watchdog::default();
        let t0 = Instant::now();
        running(&watchdog, 1, t0);
        running(&watchdog, 2, t0);
        watchdog.invocation_began(1, 7, "f1.ts#a".into(), 10 * SECOND, t0);
        watchdog.poll_began(2, t0);
        // Worker 1's long invocation does not extend worker 2's budget.
        let findings = watchdog.check(t0 + 2 * SECOND);
        assert!(matches!(findings.as_slice(), [Finding::Stuck { worker: 2, .. }]), "{findings:?}");
    }

    #[test]
    fn loading_has_one_deadline_for_everything() {
        let watchdog = Watchdog::default();
        let t0 = Instant::now();
        watchdog.add_worker(1, "f1.ts".into(), 5 * SECOND, t0);
        watchdog.poll_began(1, t0);
        // Synchronous top-level code longer than the timer budget is fine.
        assert_eq!(watchdog.check(t0 + 3 * SECOND), NOTHING);
        watchdog.poll_ended(1, t0);
        assert_eq!(watchdog.check(t0 + 6 * SECOND), [Finding::LoadOverran { worker: 1, deadline: 5 * SECOND }]);
        assert!(watchdog.check(t0 + 7 * SECOND).is_empty(), "reported once");
    }

    #[test]
    fn removing_a_worker_drops_its_invocations() {
        let watchdog = Watchdog::default();
        let t0 = Instant::now();
        running(&watchdog, 1, t0);
        watchdog.invocation_began(1, 7, "f1.ts#a".into(), SECOND, t0);
        watchdog.remove_worker(1);
        assert_eq!(watchdog.check(t0 + 5 * SECOND), NOTHING);
    }
}
