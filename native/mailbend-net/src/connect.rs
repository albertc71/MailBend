//! TCP connections under one deadline: name resolution (bounded even for
//! the system resolver) and connection attempts raced across addresses.

use std::io::{self, Read, Write};
use std::net::{IpAddr, SocketAddr, TcpStream, ToSocketAddrs};
use std::sync::Arc;
use std::sync::mpsc::{self, RecvTimeoutError};
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

/// Races connections to `addrs` as RFC 8305 describes: the address families
/// alternate, and the next attempt starts as soon as one fails or after
/// `ATTEMPT_DELAY`, sooner when the time left would otherwise not reach
/// every address. The first socket to connect by the deadline wins. When
/// none does, the error is the last address's, as when the addresses were
/// tried in turn.
pub fn connect_any(addrs: &[SocketAddr], deadline: &Deadline) -> Result<TcpStream, NetError> {
    race(addrs, deadline, Arc::new(TcpStream::connect_timeout))
}

/// Opens a TCP connection to an address within a timeout.
type Connector = Arc<dyn Fn(&SocketAddr, Duration) -> io::Result<TcpStream> + Send + Sync>;

/// An address's position in the caller's list, and how its attempt ended.
type Outcome = (usize, Result<TcpStream, NetError>);

/// `connect_any` with the connecting step given, so tests can stand in for
/// peers that answer late or never.
fn race(
    addrs: &[SocketAddr],
    deadline: &Deadline,
    connect: Connector,
) -> Result<TcpStream, NetError> {
    // An address never started ran out of time, as with attempts in turn.
    let mut errors = vec![NetError::TimedOut; addrs.len()];
    let (report, outcomes) = mpsc::channel();
    // Each attempt holds a sender, so the channel disconnects once every
    // attempt has been started and has reported.
    let mut waiting = alternate_families(addrs)
        .into_iter()
        .map(|attempt| (attempt, report.clone()))
        .collect::<Vec<_>>()
        .into_iter();
    drop(report);
    loop {
        if let Some(((index, addr), report)) = waiting.next() {
            if let Err(e) = start_attempt(index, addr, deadline, Arc::clone(&connect), report) {
                errors[index] = e;
                continue;
            }
            errors[index] = attempt_timed_out();
        }
        let left = deadline.remaining().ok();
        // Past the deadline, take only the outcomes already queued.
        let wait = left.map_or(Duration::ZERO, |left| wait_for_outcome(left, waiting.len()));
        match outcomes.recv_timeout(wait) {
            Ok((_, Ok(sock))) if deadline.remaining().is_ok() => return Ok(sock),
            Ok((index, outcome)) => errors[index] = outcome.err().unwrap_or_else(attempt_timed_out),
            Err(RecvTimeoutError::Timeout) if left.is_some() => {}
            Err(_) => break,
        }
    }
    Err(errors
        .pop()
        .unwrap_or_else(|| NetError::Connect("no addresses".to_string())))
}

/// How long to wait for an outcome after starting an attempt while
/// `waiting` addresses are still to start: `ATTEMPT_DELAY`, or the attempt's
/// equal share of the time `left` when that is shorter, so every address
/// starts before the deadline. With none waiting, all the time left.
fn wait_for_outcome(left: Duration, waiting: usize) -> Duration {
    if waiting == 0 {
        return left;
    }
    let shares = u32::try_from(waiting).map_or(u32::MAX, |n| n.saturating_add(1));
    (left / shares).min(ATTEMPT_DELAY)
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

/// Connects to `addr` on its own thread, within what is left of `deadline`,
/// and sends the outcome to `report`. Once `connect_any` has returned
/// nobody receives, so a socket that connects too late is dropped, which
/// closes it.
fn start_attempt(
    index: usize,
    addr: SocketAddr,
    deadline: &Deadline,
    connect: Connector,
    report: mpsc::Sender<Outcome>,
) -> Result<(), NetError> {
    let left = deadline.remaining()?;
    std::thread::Builder::new()
        .name("connect".to_string())
        .spawn(move || {
            let outcome = connect(&addr, left).map_err(|e| NetError::Connect(e.to_string()));
            let _too_late = report.send((index, outcome));
        })
        .map(drop)
        .map_err(|_| NetError::Connect("cannot start a connection attempt".to_string()))
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
    use std::net::TcpListener;
    use std::sync::Mutex;

    fn closed_port() -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        listener.local_addr().expect("addr")
    }

    #[test]
    fn falls_back_to_the_address_that_listens() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let good = listener.local_addr().expect("addr");
        let deadline = Deadline::after(Duration::from_secs(2));
        let sock = connect_any(&[closed_port(), good], &deadline).expect("connect");
        assert_eq!(sock.peer_addr().expect("peer"), good);
    }

    #[test]
    fn the_first_socket_to_connect_wins_and_a_late_loser_is_closed() {
        let slow = TcpListener::bind("127.0.0.1:0").expect("bind");
        let slow_addr = slow.local_addr().expect("addr");
        let fast = TcpListener::bind("127.0.0.1:0").expect("bind");
        let fast_addr = fast.local_addr().expect("addr");
        let (release, held) = mpsc::channel::<()>();
        let held = Mutex::new(held);
        let connect: Connector = Arc::new(move |addr: &SocketAddr, timeout: Duration| {
            if *addr == slow_addr {
                let _released = held
                    .lock()
                    .expect("lock")
                    .recv_timeout(Duration::from_secs(2));
            }
            TcpStream::connect_timeout(addr, timeout)
        });
        let deadline = Deadline::after(Duration::from_secs(5));
        let sock = race(&[slow_addr, fast_addr], &deadline, connect).expect("connect");
        assert_eq!(sock.peer_addr().expect("peer"), fast_addr);

        let (accepted, late) = mpsc::channel();
        std::thread::spawn(move || accepted.send(slow.accept()));
        let _attempt_gone = release.send(());
        let (mut loser, _) = late
            .recv_timeout(Duration::from_secs(2))
            .expect("the losing attempt connects late")
            .expect("accept");
        loser
            .set_read_timeout(Some(Duration::from_secs(1)))
            .expect("timeout");
        assert_eq!(loser.read(&mut [0; 1]).expect("closed, not kept open"), 0);
    }

    #[test]
    fn attempts_alternate_address_families_starting_with_the_first_listed() {
        let v6 = |last| SocketAddr::from(([0x2001, 0xdb8, 0, 0, 0, 0, 0, last], 993));
        let v4 = |last| SocketAddr::from(([192, 0, 2, last], 993));
        assert_eq!(
            alternate_families(&[v6(1), v6(2), v6(3), v4(1)]),
            [(0, v6(1)), (3, v4(1)), (1, v6(2)), (2, v6(3))]
        );
        assert_eq!(
            alternate_families(&[v4(1), v4(2), v6(1), v6(2)]),
            [(0, v4(1)), (2, v6(1)), (1, v4(2)), (3, v6(2))]
        );
    }

    #[test]
    fn the_next_attempt_waits_250_ms_or_an_equal_share_of_a_short_budget() {
        let ms = Duration::from_millis;
        assert_eq!(wait_for_outcome(ms(30_000), 2), ms(250));
        assert_eq!(wait_for_outcome(ms(100), 1), ms(50));
        assert_eq!(wait_for_outcome(ms(400), 2), ms(400) / 3);
        assert_eq!(wait_for_outcome(ms(100), 0), ms(100));
    }

    #[test]
    fn an_attempt_that_connects_too_late_fails_at_the_deadline() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        let stalls: Connector = Arc::new(|addr: &SocketAddr, timeout: Duration| {
            std::thread::sleep(Duration::from_secs(1));
            TcpStream::connect_timeout(addr, timeout)
        });
        for budget in [Duration::from_millis(50), Duration::from_millis(300)] {
            let started = Instant::now();
            let result = race(&[addr], &Deadline::after(budget), Arc::clone(&stalls));
            let waited = started.elapsed();
            assert!(
                matches!(result, Err(NetError::Connect(_))),
                "{budget:?}: {result:?}"
            );
            assert!(
                (budget..budget + Duration::from_millis(200)).contains(&waited),
                "a {budget:?} deadline returned after {waited:?}"
            );
        }
    }

    /// How a stand-in peer answers a connection attempt.
    #[derive(Clone, Copy, Debug, PartialEq)]
    enum Peer {
        Refuses,
        Unreachable,
        /// Never answers, so the attempt gives up at its timeout.
        Silent,
    }

    impl Peer {
        fn failure(self) -> io::Error {
            match self {
                Peer::Refuses => io::ErrorKind::ConnectionRefused.into(),
                Peer::Unreachable => io::ErrorKind::NetworkUnreachable.into(),
                Peer::Silent => io::Error::new(io::ErrorKind::TimedOut, "connection timed out"),
            }
        }

        fn answer(self, timeout: Duration) -> io::Result<TcpStream> {
            if self == Peer::Silent {
                std::thread::sleep(timeout);
            }
            Err(self.failure())
        }
    }

    /// Races peers listed in order, each an IPv6 (`true`) or IPv4 address,
    /// with every attempt failing as its peer does.
    fn race_failing(peers: &[(bool, Peer)], budget: Duration) -> Result<TcpStream, NetError> {
        let answers: Vec<(SocketAddr, Peer)> = (1u8..)
            .zip(peers)
            .map(|(last, &(v6, peer))| match v6 {
                true => (
                    ([0x2001, 0xdb8, 0, 0, 0, 0, 0, last.into()], 993).into(),
                    peer,
                ),
                false => (([192, 0, 2, last], 993).into(), peer),
            })
            .collect();
        let addrs: Vec<_> = answers.iter().map(|&(addr, _)| addr).collect();
        let connect: Connector = Arc::new(move |addr: &SocketAddr, timeout: Duration| {
            let (_, peer) = answers
                .iter()
                .find(|(listed, _)| listed == addr)
                .expect("listed");
            peer.answer(timeout)
        });
        race(&addrs, &Deadline::after(budget), connect)
    }

    #[test]
    fn when_every_attempt_fails_the_error_is_the_last_address_s_as_when_tried_in_turn() {
        let kinds: Vec<(bool, Peer)> = [true, false]
            .into_iter()
            .flat_map(|v6| [Peer::Refuses, Peer::Unreachable, Peer::Silent].map(|peer| (v6, peer)))
            .collect();
        let mut mixes = vec![Vec::new()];
        let mut every_mix = Vec::new();
        for _ in 0..3 {
            mixes = mixes
                .iter()
                .flat_map(|mix| {
                    kinds
                        .iter()
                        .map(move |&kind| [mix.clone(), vec![kind]].concat())
                })
                .collect();
            every_mix.extend(mixes.iter().cloned());
        }
        let budget = Duration::from_millis(200);
        let mut wrong = Vec::new();
        // Racing every mix at once can delay thread starts past the deadline.
        for batch in every_mix.chunks(32) {
            std::thread::scope(|scope| {
                let races: Vec<_> = batch
                    .iter()
                    .map(|mix| scope.spawn(move || (mix, race_failing(mix, budget).err())))
                    .collect();
                wrong.extend(
                    races
                        .into_iter()
                        .map(|race| race.join().expect("race"))
                        .filter(|(mix, error)| {
                            let (_, last) = mix.last().expect("a peer");
                            *error != Some(NetError::Connect(last.failure().to_string()))
                        }),
                );
            });
        }
        assert!(
            wrong.is_empty(),
            "{} of {} mixes: {wrong:?}",
            wrong.len(),
            every_mix.len()
        );
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
