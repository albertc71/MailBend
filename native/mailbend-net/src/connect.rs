//! TCP connections under one deadline: name resolution (bounded even for
//! the system resolver) and connection attempts raced across addresses.

use std::io::{self, Read, Write};
use std::net::{IpAddr, SocketAddr, TcpStream, ToSocketAddrs};
use std::sync::{Arc, mpsc};
use std::time::{Duration, Instant};

use rustls::ClientConfig;

use crate::NetError;
use crate::doh::Resolver;

/// One time budget shared by resolution, connecting and the DoH exchange.
#[derive(Clone, Copy, Debug)]
pub struct Deadline(Instant);

impl Deadline {
    pub fn after(budget: Duration) -> Self {
        Deadline(Instant::now() + budget)
    }

    /// The time left, or `TimedOut` once it has run out.
    pub fn remaining(&self) -> Result<Duration, NetError> {
        let left = self.0.saturating_duration_since(Instant::now());
        if left.is_zero() {
            Err(NetError::TimedOut)
        } else {
            Ok(left)
        }
    }

    /// This deadline, or `share` from now when that comes first.
    fn sooner(&self, share: Duration) -> Deadline {
        Deadline(self.0.min(Instant::now() + share))
    }
}

/// A socket whose every read and write is bounded by the time left, so no
/// sequence of operations (a TLS handshake, a slowly dripped response) can
/// outlast the deadline. A socket timeout alone applies per operation.
pub struct BoundedStream {
    sock: TcpStream,
    deadline: Deadline,
}

impl BoundedStream {
    pub fn new(sock: TcpStream, deadline: Deadline) -> Self {
        BoundedStream { sock, deadline }
    }

    pub fn into_inner(self) -> TcpStream {
        self.sock
    }

    fn bound(&self) -> io::Result<()> {
        let left = self
            .deadline
            .remaining()
            .map_err(|_| io::Error::from(io::ErrorKind::TimedOut))?;
        self.sock.set_read_timeout(Some(left))?;
        self.sock.set_write_timeout(Some(left))
    }
}

impl Read for BoundedStream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.bound()?;
        self.sock.read(buf)
    }
}

impl Write for BoundedStream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.bound()?;
        self.sock.write(buf)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.sock.flush()
    }
}

/// Resolves `host` with the system resolver; an IP literal needs no lookup.
/// getaddrinfo cannot be interrupted, so it runs on its own thread and is
/// abandoned when the deadline passes (the process exits soon after).
pub fn resolve_system(
    host: &str,
    port: u16,
    deadline: &Deadline,
) -> Result<Vec<SocketAddr>, NetError> {
    if let Ok(ip) = host.parse::<IpAddr>() {
        return Ok(vec![SocketAddr::new(ip, port)]);
    }
    let (send, receive) = mpsc::channel();
    let target = (host.to_string(), port);
    std::thread::Builder::new()
        .name("resolver".to_string())
        .spawn(move || {
            let result = target.to_socket_addrs().map(Iterator::collect::<Vec<_>>);
            let _receiver_gone = send.send(result.map_err(|e| e.to_string()));
        })
        .map_err(|_| NetError::Dns("cannot start name resolution".to_string()))?;
    match receive.recv_timeout(deadline.remaining()?) {
        Ok(Ok(addrs)) if !addrs.is_empty() => Ok(addrs),
        Ok(Ok(_)) => Err(NetError::Dns(format!("{host} has no addresses"))),
        Ok(Err(e)) => Err(NetError::Dns(format!("cannot resolve {host}: {e}"))),
        Err(mpsc::RecvTimeoutError::Timeout) => Err(NetError::TimedOut),
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            Err(NetError::Dns(format!("cannot resolve {host}")))
        }
    }
}

/// The addresses of `host:port`, from the DoH resolver when one is given,
/// else from system DNS.
pub fn resolve(
    doh: Option<&Resolver>,
    config: &Arc<ClientConfig>,
    host: &str,
    port: u16,
    deadline: &Deadline,
) -> Result<Vec<SocketAddr>, NetError> {
    match doh {
        Some(resolver) => Ok(resolver
            .resolve(config, host, deadline)?
            .into_iter()
            .map(|ip| SocketAddr::new(ip, port))
            .collect()),
        None => resolve_system(host, port, deadline),
    }
}

/// RFC 8305's recommended Connection Attempt Delay.
const ATTEMPT_DELAY: Duration = Duration::from_millis(250);

/// Staggers connection attempts to `addrs` while time remains, in a design
/// inspired by RFC 8305 section 5 rather than an implementation of it. The
/// address families alternate, and the next attempt starts as soon as one
/// fails or after `ATTEMPT_DELAY`, sooner when little time is left; with
/// many addresses and little time, the last ones may not start. Each
/// attempt dials within the time left, so once none is left to start, the
/// race waits for those still running, which end by the deadline unless
/// their threads are held up. It returns the first eligible socket
/// reported: one whose attempt connected before the deadline. When none
/// does, the error is the last address's, as when the addresses were tried
/// in turn.
pub fn connect_any(addrs: &[SocketAddr], deadline: &Deadline) -> Result<TcpStream, NetError> {
    connect_with(
        addrs,
        deadline,
        Arc::new(TcpStream::connect_timeout),
        spawn_thread,
    )
}

/// Opens a TCP connection to an address within a timeout.
type Connector = Arc<dyn Fn(&SocketAddr, Duration) -> io::Result<TcpStream> + Send + Sync>;

/// An address's position in the caller's list, and how its attempt ended.
type Outcome<T> = (usize, Result<T, NetError>);

/// An attempt on one address that waits for its turn and then yields how
/// it ended, or yields nothing when its turn never comes.
type Job = Box<dyn FnOnce() -> Option<Outcome<TcpStream>> + Send>;

/// Runs `job` on a thread of its own and sends how it ended to `report`,
/// or fails when no thread can start.
fn spawn_thread(job: Job, report: mpsc::Sender<Outcome<TcpStream>>) -> io::Result<()> {
    std::thread::Builder::new()
        .name("connect".to_string())
        .spawn(move || {
            if let Some(outcome) = job() {
                // Once connect_any has returned nobody receives, so a
                // socket that connects then is dropped, which closes it.
                let _too_late = report.send(outcome);
            }
        })
        .map(drop)
}

/// `connect_any` with the connecting and thread-starting steps given, so
/// tests can stand in for peers that answer late or never, for reports
/// held up, and for a process that cannot start every thread. Every
/// address gets a thread that waits for its turn, or none does and the
/// calling thread tries the addresses in turn: it never dials while an
/// attempt it must hear from is running. It starts the attempts `Race`
/// chooses and waits as long as it says, then waits for the attempts still
/// running.
fn connect_with(
    addrs: &[SocketAddr],
    deadline: &Deadline,
    connect: Connector,
    mut spawn: impl FnMut(Job, mpsc::Sender<Outcome<TcpStream>>) -> io::Result<()>,
) -> Result<TcpStream, NetError> {
    let mut race = Race::new(addrs);
    let (report, outcomes) = mpsc::channel();
    let turns: Option<Vec<mpsc::Sender<()>>> = addrs
        .iter()
        .enumerate()
        .map(|(index, &addr)| {
            // Past the deadline no attempt starts, so no thread is needed.
            deadline.remaining().ok()?;
            let (turn, my_turn) = mpsc::channel();
            let (connect, deadline) = (Arc::clone(&connect), *deadline);
            let job: Job = Box::new(move || {
                my_turn.recv().ok()?;
                Some((index, attempt(&addr, &deadline, &*connect)))
            });
            spawn(job, report.clone()).ok().map(|()| turn)
        })
        // Stops at the first thread that cannot start. Dropping the turns
        // gathered so far lets those threads end without dialling.
        .collect();
    while let Some(step) = race.next(deadline.remaining().ok()) {
        let heard = match (step, &turns) {
            (Step::Start(index, ..), Some(turns)) => {
                let _gone = turns[index].send(());
                continue;
            }
            // Not every address has a thread: try this one here, within its
            // share of the time left, as when trying the addresses in turn.
            (Step::Start(index, addr, share), None) => {
                Some((index, attempt(&addr, &deadline.sooner(share), &*connect)))
            }
            (Step::Wait(wait), _) => outcomes.recv_timeout(wait).ok(),
        };
        if let Some(connected) = race.heard(heard) {
            return Ok(connected);
        }
    }
    drop(turns);
    drop(report);
    race.settle(outcomes)
}

/// What the race does next.
enum Step {
    /// Start the attempt on the address at this position in the caller's
    /// list. The duration is the attempt's equal share of the time left,
    /// which bounds it when it cannot run beside the others.
    Start(usize, SocketAddr, Duration),
    /// Wait up to this long for an attempt to end.
    Wait(Duration),
}

/// The race's decisions, free of threads, sockets and the clock: which
/// attempt starts next and when, how outcomes count, and what the race
/// returns.
struct Race {
    /// Attempts not yet started, in the order they start.
    waiting: std::vec::IntoIter<(usize, SocketAddr)>,
    /// Attempts started that have not ended.
    running: usize,
    /// Whether the next attempt may start now: none has started yet, or
    /// one failed, or the last wait passed.
    due: bool,
    /// The position of the last address in the caller's list.
    last: usize,
    /// The last address's error, should none connect. An address never
    /// started ran out of time, as with attempts in turn.
    error: NetError,
}

impl Race {
    fn new(addrs: &[SocketAddr]) -> Self {
        Race {
            waiting: alternate_families(addrs).into_iter(),
            running: 0,
            due: true,
            last: addrs.len().saturating_sub(1),
            error: if addrs.is_empty() {
                NetError::Connect("no addresses".to_string())
            } else {
                NetError::TimedOut
            },
        }
    }

    /// The next step, given the time `left` before the deadline (`None`
    /// once it has passed), or `None` when no attempt starts again. After
    /// an attempt starts, the next one waits `ATTEMPT_DELAY`, or the
    /// attempt's equal share of the time left when that is shorter, so
    /// that, time permitting, every address starts before the deadline.
    fn next(&mut self, left: Option<Duration>) -> Option<Step> {
        let left = left?;
        if self.waiting.as_slice().is_empty() {
            return None;
        }
        if !self.due {
            let wait = share(left, self.waiting.len()).min(ATTEMPT_DELAY);
            return Some(Step::Wait(wait));
        }
        let (index, addr) = self.waiting.next()?;
        self.running += 1;
        self.due = false;
        Some(Step::Start(index, addr, share(left, self.waiting.len())))
    }

    /// Takes in what a wait brought: an attempt's outcome, or nothing when
    /// the wait passed. Returns what an attempt that connected yields.
    fn heard<T>(&mut self, outcome: Option<Outcome<T>>) -> Option<T> {
        self.due = true;
        let (index, result) = outcome?;
        self.running -= 1;
        match result {
            Ok(connected) => Some(connected),
            Err(e) => {
                if index == self.last {
                    self.error = e;
                }
                None
            }
        }
    }

    /// Waits out the attempts still running: the first to report a socket
    /// wins, else the race fails with the last address's error.
    fn settle<T>(mut self, outcomes: impl IntoIterator<Item = Outcome<T>>) -> Result<T, NetError> {
        let mut outcomes = outcomes.into_iter();
        while self.running > 0
            && let Some(outcome) = outcomes.next()
        {
            if let Some(connected) = self.heard(Some(outcome)) {
                return Ok(connected);
            }
        }
        Err(self.error)
    }
}

/// An equal share of the time `left` for an attempt and the `waiting`
/// attempts to start after it.
fn share(left: Duration, waiting: usize) -> Duration {
    left / u32::try_from(waiting).map_or(u32::MAX, |n| n.saturating_add(1))
}

/// `addrs` with their positions, the address families alternating and
/// starting with the family listed first.
fn alternate_families(addrs: &[SocketAddr]) -> Vec<(usize, SocketAddr)> {
    let first_is_v4 = addrs.first().is_some_and(SocketAddr::is_ipv4);
    let (first, other): (Vec<_>, Vec<_>) = addrs
        .iter()
        .copied()
        .enumerate()
        .partition(|(_, addr)| addr.is_ipv4() == first_is_v4);
    let mut other = other.into_iter();
    let mut order: Vec<_> = first
        .into_iter()
        .flat_map(|attempt| std::iter::once(attempt).chain(other.next()))
        .collect();
    order.extend(other);
    order
}

/// Connects to `addr` within the time left. The attempt samples the
/// remaining budget before it calls connect and skips the call when none is
/// left, though a thread held up between the two can still dial after the
/// deadline. It accepts a result only if its deadline check after the call
/// passes: what it hears later, a socket or a refusal, counts as a timeout,
/// because the address did not answer in time. A late socket is dropped,
/// which closes it.
fn attempt<T>(
    addr: &SocketAddr,
    deadline: &Deadline,
    connect: impl Fn(&SocketAddr, Duration) -> io::Result<T>,
) -> Result<T, NetError> {
    let outcome = connect(addr, deadline.remaining()?);
    deadline.remaining().map_err(|_| attempt_timed_out())?;
    outcome.map_err(|e| NetError::Connect(e.to_string()))
}

/// How an attempt still unanswered at the deadline fails, in the words
/// `TcpStream::connect_timeout` uses for its own timeout.
fn attempt_timed_out() -> NetError {
    NetError::Connect("connection timed out".to_string())
}

/// Bounds every later read and write on `sock` by `timeout`.
pub fn set_timeouts(sock: &TcpStream, timeout: Duration) -> Result<(), NetError> {
    sock.set_read_timeout(Some(timeout))
        .and_then(|()| sock.set_write_timeout(Some(timeout)))
        .map_err(|_| NetError::Connect("cannot configure the connected socket".to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::net::TcpListener;
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn falls_back_to_the_address_that_listens() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let good = listener.local_addr().expect("addr");
        let closed = {
            let l = TcpListener::bind("127.0.0.1:0").expect("bind");
            l.local_addr().expect("addr")
        };
        let deadline = Deadline::after(Duration::from_secs(2));
        let sock = connect_any(&[closed, good], &deadline).expect("connect");
        assert_eq!(sock.peer_addr().expect("peer"), good);
    }

    /// Stands in for a connect call that does not return until `release`
    /// is dropped or `hold` passes.
    fn held_until_released(hold: Duration) -> (mpsc::Sender<()>, impl Fn() + Send + Sync) {
        let (release, held) = mpsc::channel::<()>();
        let held = Mutex::new(held);
        let stall = move || {
            let _released = held.lock().expect("lock").recv_timeout(hold);
        };
        (release, stall)
    }

    #[test]
    fn a_black_holed_address_costs_one_attempt_delay_and_its_late_socket_is_closed() {
        let black_holed = TcpListener::bind("127.0.0.1:0").expect("bind");
        let black_holed_addr = black_holed.local_addr().expect("addr");
        let listening = TcpListener::bind("127.0.0.1:0").expect("bind");
        let listening_addr = listening.local_addr().expect("addr");
        let budget = Duration::from_secs(30);
        // Held until the race is over or its deadline has passed, so it
        // cannot win however the threads are scheduled.
        let (release, stall) = held_until_released(budget);
        let connect: Connector = Arc::new(move |addr: &SocketAddr, timeout: Duration| {
            if *addr == black_holed_addr {
                stall();
            }
            TcpStream::connect_timeout(addr, timeout)
        });
        let started = Instant::now();
        let addrs = [black_holed_addr, listening_addr];
        let sock =
            connect_with(&addrs, &Deadline::after(budget), connect, spawn_thread).expect("connect");
        let took = started.elapsed();
        assert_eq!(sock.peer_addr().expect("peer"), listening_addr);
        assert!(
            (ATTEMPT_DELAY..budget / 2).contains(&took),
            "connected after {took:?}"
        );

        let (accepted, late) = mpsc::channel();
        std::thread::spawn(move || accepted.send(black_holed.accept()));
        drop(release);
        let (mut loser, _) = late
            .recv_timeout(Duration::from_secs(30))
            .expect("the losing attempt connects late")
            .expect("accept");
        loser
            .set_read_timeout(Some(Duration::from_secs(30)))
            .expect("timeout");
        assert_eq!(loser.read(&mut [0; 1]).expect("closed, not kept open"), 0);
    }

    /// Stands in for a peer that never answers: the connect call waits out
    /// its timeout, as `TcpStream::connect_timeout` does.
    fn never_answers(_: &SocketAddr, timeout: Duration) -> io::Result<TcpStream> {
        std::thread::sleep(timeout);
        Err(io::ErrorKind::TimedOut.into())
    }

    #[test]
    fn attempts_that_never_answer_fail_at_the_deadline() {
        let budget = Duration::from_millis(100);
        let addrs = [([192, 0, 2, 1], 993).into(), ([192, 0, 2, 2], 993).into()];
        let started = Instant::now();
        let deadline = Deadline::after(budget);
        let result = connect_with(&addrs, &deadline, Arc::new(never_answers), spawn_thread);
        let took = started.elapsed();
        assert!(result.is_err(), "{result:?}");
        assert!(
            (budget..Duration::from_secs(10)).contains(&took),
            "a {budget:?} budget returned after {took:?}"
        );
    }

    #[test]
    fn a_success_reported_after_the_deadline_still_wins() {
        let listening = TcpListener::bind("127.0.0.1:0").expect("bind");
        let listening_addr = listening.local_addr().expect("addr");
        let budget = Duration::from_millis(100);
        let hold = Duration::from_millis(150);
        // Holds each report back after the attempt has ended, as when its
        // thread is held up between connecting and reporting.
        let report_late = move |job: Job, report: mpsc::Sender<Outcome<TcpStream>>| {
            std::thread::Builder::new()
                .spawn(move || {
                    if let Some(outcome) = job() {
                        std::thread::sleep(hold);
                        let _too_late = report.send(outcome);
                    }
                })
                .map(drop)
        };
        let connect: Connector = Arc::new(TcpStream::connect_timeout);
        let deadline = Deadline::after(budget);
        let started = Instant::now();
        let sock = connect_with(&[listening_addr], &deadline, connect, report_late)
            .expect("connected in time, reported late");
        assert_eq!(sock.peer_addr().expect("peer"), listening_addr);
        assert!(started.elapsed() >= hold, "the report was not held back");
    }

    #[test]
    fn without_threads_each_address_is_tried_in_turn_for_its_share_of_the_time() {
        let black_holed = SocketAddr::from(([192, 0, 2, 1], 993));
        let listening = TcpListener::bind("127.0.0.1:0").expect("bind");
        let listening_addr = listening.local_addr().expect("addr");
        let connect: Connector = Arc::new(move |addr: &SocketAddr, timeout: Duration| {
            if *addr == black_holed {
                return never_answers(addr, timeout);
            }
            TcpStream::connect_timeout(addr, timeout)
        });
        let no_thread = |_: Job, _: mpsc::Sender<_>| Err(io::ErrorKind::WouldBlock.into());
        let budget = Duration::from_millis(400);
        let started = Instant::now();
        let addrs = [black_holed, listening_addr];
        let sock = connect_with(&addrs, &Deadline::after(budget), connect, no_thread)
            .expect("the listening address is reached");
        let took = started.elapsed();
        assert_eq!(sock.peer_addr().expect("peer"), listening_addr);
        assert!(took >= budget / 4, "the black-holed address had {took:?}");
    }

    /// Starts the first thread it is asked for and no other, as in a
    /// process one thread short of its limit.
    fn one_thread_only() -> impl FnMut(Job, mpsc::Sender<Outcome<TcpStream>>) -> io::Result<()> {
        let mut started = false;
        move |job, report| {
            if std::mem::replace(&mut started, true) {
                return Err(io::ErrorKind::WouldBlock.into());
            }
            spawn_thread(job, report)
        }
    }

    #[test]
    fn a_thread_short_an_address_that_connects_is_not_held_up() {
        let first = TcpListener::bind("127.0.0.1:0").expect("bind");
        let first_addr = first.local_addr().expect("addr");
        let black_holed = SocketAddr::from(([192, 0, 2, 1], 993));
        let dials = Arc::new(AtomicUsize::new(0));
        let dialled = Arc::clone(&dials);
        let connect: Connector = Arc::new(move |addr: &SocketAddr, timeout: Duration| {
            if *addr == black_holed {
                return never_answers(addr, timeout);
            }
            dialled.fetch_add(1, Ordering::SeqCst);
            // Still connecting when the next attempt is due.
            std::thread::sleep(ATTEMPT_DELAY * 2);
            TcpStream::connect_timeout(addr, timeout)
        });
        let budget = Duration::from_secs(2);
        let started = Instant::now();
        let addrs = [first_addr, black_holed];
        let sock = connect_with(&addrs, &Deadline::after(budget), connect, one_thread_only())
            .expect("the first address is reached");
        let took = started.elapsed();
        assert_eq!(sock.peer_addr().expect("peer"), first_addr);
        assert!(took < budget / 2, "connected after {took:?}");
        assert_eq!(dials.load(Ordering::SeqCst), 1, "dialled twice");
    }

    #[test]
    fn starting_threads_slowly_cannot_outlast_the_deadline() {
        let addrs: Vec<SocketAddr> = (1..=20).map(|n| ([192, 0, 2, n], 993).into()).collect();
        let slow_start = |job: Job, report: mpsc::Sender<Outcome<TcpStream>>| {
            std::thread::sleep(Duration::from_millis(10));
            spawn_thread(job, report)
        };
        let budget = Duration::from_millis(50);
        let deadline = Deadline::after(budget);
        let started = Instant::now();
        let result = connect_with(&addrs, &deadline, Arc::new(never_answers), slow_start);
        let took = started.elapsed();
        assert!(result.is_err(), "{result:?}");
        assert!(took < budget * 3, "returned after {took:?}");
    }

    #[test]
    fn a_thread_short_every_address_still_gets_its_turn() {
        let black_holed = SocketAddr::from(([192, 0, 2, 1], 993));
        let listening = TcpListener::bind("127.0.0.1:0").expect("bind");
        let listening_addr = listening.local_addr().expect("addr");
        let connect: Connector = Arc::new(move |addr: &SocketAddr, timeout: Duration| {
            if *addr == black_holed {
                return never_answers(addr, timeout);
            }
            TcpStream::connect_timeout(addr, timeout)
        });
        let budget = Duration::from_millis(400);
        let addrs = [black_holed, listening_addr];
        let sock = connect_with(&addrs, &Deadline::after(budget), connect, one_thread_only())
            .expect("the listening address is reached");
        assert_eq!(sock.peer_addr().expect("peer"), listening_addr);
    }

    #[test]
    fn a_long_list_reaches_its_listener_with_few_descriptors_free() {
        // The sockets a process near its descriptor limit can still open: a
        // dial beyond them fails at once, as socket() does with EMFILE.
        const FREE_DESCRIPTORS: usize = 8;
        let listening = TcpListener::bind("127.0.0.1:0").expect("bind");
        let listening_addr = listening.local_addr().expect("addr");
        let silent: Vec<SocketAddr> = (1..=20).map(|n| ([192, 0, 2, n], 993).into()).collect();
        let refusing = (1..=43).map(|n| SocketAddr::from(([198, 51, 100, n], 993)));
        let addrs: Vec<_> = silent
            .iter()
            .copied()
            .chain([listening_addr])
            .chain(refusing)
            .collect();
        let (open, most) = (Arc::new(AtomicUsize::new(0)), Arc::new(AtomicUsize::new(0)));
        let connect: Connector = {
            let (open, most) = (Arc::clone(&open), Arc::clone(&most));
            Arc::new(move |addr: &SocketAddr, timeout: Duration| {
                let held = open.fetch_add(1, Ordering::SeqCst) + 1;
                most.fetch_max(held, Ordering::SeqCst);
                let dialled = if held > FREE_DESCRIPTORS {
                    Err(io::Error::other("too many open files"))
                } else if *addr == listening_addr {
                    TcpStream::connect_timeout(addr, timeout)
                } else if silent.contains(addr) {
                    never_answers(addr, timeout)
                } else {
                    Err(io::ErrorKind::ConnectionRefused.into())
                };
                open.fetch_sub(1, Ordering::SeqCst);
                dialled
            })
        };
        let budget = Duration::from_secs(1);
        let started = Instant::now();
        let sock = connect_with(&addrs, &Deadline::after(budget), connect, spawn_thread)
            .expect("the listening address is reached");
        let took = started.elapsed();
        assert_eq!(sock.peer_addr().expect("peer"), listening_addr);
        assert!(took < budget * 3 / 4, "connected after {took:?}");
        let most = most.load(Ordering::SeqCst);
        assert!(most <= FREE_DESCRIPTORS, "{most} dials at once");
    }

    #[test]
    fn an_attempt_skips_the_dial_without_time_left_and_rejects_a_late_success() {
        let addr = SocketAddr::from(([192, 0, 2, 1], 993));
        let dialled = Cell::new(false);
        let dial = |_: &SocketAddr, _: Duration| -> io::Result<()> {
            dialled.set(true);
            Ok(())
        };
        let expired = Deadline(Instant::now());
        assert_eq!(attempt(&addr, &expired, dial), Err(NetError::TimedOut));
        assert!(!dialled.get(), "dialled after the deadline");

        let outlasts_its_timeout = |_: &SocketAddr, timeout: Duration| -> io::Result<()> {
            std::thread::sleep(timeout);
            Ok(())
        };
        let deadline = Deadline::after(Duration::from_millis(20));
        assert!(attempt(&addr, &deadline, outlasts_its_timeout).is_err());
    }

    #[test]
    fn a_refusal_heard_after_the_deadline_counts_as_a_timeout() {
        let addr = SocketAddr::from(([192, 0, 2, 1], 993));
        let refuses_late = |_: &SocketAddr, timeout: Duration| -> io::Result<()> {
            std::thread::sleep(timeout);
            Err(io::ErrorKind::ConnectionRefused.into())
        };
        let deadline = Deadline::after(Duration::from_millis(20));
        assert_eq!(
            attempt(&addr, &deadline, refuses_late),
            Err(attempt_timed_out())
        );
    }

    /// How a scripted peer's attempt reports, this many milliseconds after
    /// it starts. A report can come after the deadline when the attempt's
    /// thread is held up after its connection is made. A silent peer's
    /// attempt times out at the deadline.
    #[derive(Clone, Copy, Debug)]
    enum Answer {
        Connects(u64),
        Fails(u64),
        Silent,
    }

    /// The error a scripted peer at `addr` fails with.
    fn failure(addr: SocketAddr) -> NetError {
        NetError::Connect(format!("{addr} refused"))
    }

    /// Runs `Race` against scripted peers on a simulated clock with `budget`
    /// milliseconds to spend. Returns what it returned and when each
    /// address's attempt started, if it did, in whole milliseconds.
    fn simulate(
        budget: u64,
        peers: &[(SocketAddr, Answer)],
    ) -> (Result<SocketAddr, NetError>, Vec<Option<u128>>) {
        let addrs: Vec<_> = peers.iter().map(|&(addr, _)| addr).collect();
        let mut race = Race::new(&addrs);
        let budget = Duration::from_millis(budget);
        let (mut now, mut starts, mut due) = (Duration::ZERO, vec![None; peers.len()], Vec::new());
        while let Some(step) = race.next(budget.checked_sub(now).filter(|left| !left.is_zero())) {
            match step {
                Step::Start(index, addr, _) => {
                    starts[index] = Some(now.as_millis());
                    let after = |ms| now + Duration::from_millis(ms);
                    let (at, outcome) = match peers[index].1 {
                        Answer::Connects(ms) => (after(ms), Ok(addr)),
                        Answer::Fails(ms) => (after(ms), Err(failure(addr))),
                        Answer::Silent => (budget, Err(attempt_timed_out())),
                    };
                    due.push((at, (index, outcome)));
                    due.sort_by_key(|&(at, _)| std::cmp::Reverse(at));
                }
                Step::Wait(wait) => {
                    let heard = match due.pop_if(|(at, _)| *at <= now + wait) {
                        Some((at, outcome)) => {
                            now = at;
                            Some(outcome)
                        }
                        None => {
                            now += wait;
                            None
                        }
                    };
                    if let Some(connected) = race.heard(heard) {
                        return (Ok(connected), starts);
                    }
                }
            }
        }
        let in_time_order = due.into_iter().rev().map(|(_, outcome)| outcome);
        (race.settle(in_time_order), starts)
    }

    #[test]
    fn attempts_start_staggered_and_the_error_is_the_last_address_s_as_when_tried_in_turn() {
        let v6 = |n| SocketAddr::from(([0x2001, 0xdb8, 0, 0, 0, 0, 0, n], 993));
        let v4 = |n| SocketAddr::from(([192, 0, 2, n], 993));
        use Answer::{Connects, Fails, Silent};
        // The budget in milliseconds, the peers, when each one's attempt
        // should start, and what the race should return.
        #[rustfmt::skip]
        let cases = [
            // A silent address delays the next attempt by one attempt delay.
            (30_000, vec![(v6(1), Silent), (v4(1), Connects(5))], vec![Some(0), Some(250)], Ok(v4(1))),
            // A failure starts the next attempt at once.
            (30_000, vec![(v4(1), Fails(10)), (v4(2), Connects(5))], vec![Some(0), Some(10)], Ok(v4(2))),
            // The families alternate, starting with the one listed first.
            (30_000, vec![(v4(1), Silent), (v4(2), Silent), (v6(1), Connects(5))],
             vec![Some(0), None, Some(250)], Ok(v6(1))),
            // With little time left, each wait is an equal share of it, so
            // every address starts before the deadline.
            (100, vec![(v6(1), Silent), (v4(1), Fails(1))], vec![Some(0), Some(50)], Err(failure(v4(1)))),
            (400, vec![(v4(1), Silent), (v4(2), Silent), (v4(3), Silent), (v4(4), Fails(0))],
             vec![Some(0), Some(100), Some(200), Some(300)], Err(failure(v4(4)))),
            // The last address in the caller's order is not the last to fail.
            (30_000, vec![(v6(1), Fails(1)), (v6(2), Fails(1)), (v4(1), Fails(1))],
             vec![Some(0), Some(2), Some(1)], Err(failure(v4(1)))),
            // An address unanswered at the deadline timed out.
            (1_000, vec![(v4(1), Fails(1)), (v4(2), Silent)], vec![Some(0), Some(1)], Err(attempt_timed_out())),
            // An address never started ran out of time.
            (0, vec![(v4(1), Connects(0))], vec![None], Err(NetError::TimedOut)),
            // A success reported after the deadline still wins, as its
            // attempt saw it connected in time, even after another attempt
            // fails: the race waits for every attempt it started.
            (100, vec![(v4(1), Connects(150))], vec![Some(0)], Ok(v4(1))),
            (100, vec![(v4(1), Silent), (v4(2), Connects(60))], vec![Some(0), Some(50)], Ok(v4(2))),
        ];
        for (budget, peers, starts, result) in cases {
            let expected = (result, starts);
            assert_eq!(simulate(budget, &peers), expected, "{budget} ms: {peers:?}");
        }
    }

    #[test]
    fn an_expired_deadline_stops_everything() {
        let deadline = Deadline::after(Duration::ZERO);
        std::thread::sleep(Duration::from_millis(2));
        assert_eq!(deadline.remaining(), Err(NetError::TimedOut));
        assert_eq!(
            resolve_system("localhost", 1, &deadline),
            Err(NetError::TimedOut)
        );
    }

    #[test]
    fn a_slowly_dripping_peer_cannot_outlast_the_deadline() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        let dripper = std::thread::spawn(move || {
            let (mut peer, _) = listener.accept().expect("accept");
            for _ in 0..30 {
                if peer.write_all(b"x").is_err() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
        });
        let started = Instant::now();
        let sock = TcpStream::connect(addr).expect("connect");
        let mut stream = BoundedStream::new(sock, Deadline::after(Duration::from_millis(300)));
        let mut byte = [0u8; 1];
        let error = loop {
            if let Err(e) = stream.read(&mut byte) {
                break e;
            }
        };
        assert!(matches!(
            error.kind(),
            io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
        ));
        assert!(started.elapsed() < Duration::from_millis(1000));
        drop(stream);
        dripper.join().expect("dripper");
    }
}
