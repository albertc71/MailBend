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
/// alternate, and each attempt starts `ATTEMPT_DELAY` after the previous one
/// or as soon as an attempt fails. The first socket to connect wins, and
/// every attempt ends by the deadline.
pub fn connect_any(addrs: &[SocketAddr], deadline: &Deadline) -> Result<TcpStream, NetError> {
    race(addrs, deadline, Arc::new(TcpStream::connect_timeout))
}

/// Opens a TCP connection to an address within a timeout.
type Connector = Arc<dyn Fn(&SocketAddr, Duration) -> io::Result<TcpStream> + Send + Sync>;

/// `connect_any` with the connecting step given, so tests can stand in for
/// peers that answer late or never.
fn race(
    addrs: &[SocketAddr],
    deadline: &Deadline,
    connect: Connector,
) -> Result<TcpStream, NetError> {
    let (report, results) = mpsc::channel();
    let mut last = NetError::Connect("no addresses".to_string());
    for addr in alternate_families(addrs) {
        let Ok(timeout) = deadline.remaining() else {
            last = NetError::TimedOut;
            break;
        };
        if let Err(e) = start_attempt(addr, timeout, Arc::clone(&connect), report.clone()) {
            last = e;
            continue;
        }
        match results.recv_timeout(ATTEMPT_DELAY) {
            Ok(Ok(sock)) => return Ok(sock),
            Ok(Err(e)) => last = e,
            Err(_delay_passed) => {}
        }
    }
    drop(report);
    for result in results {
        match result {
            Ok(sock) => return Ok(sock),
            Err(e) => last = e,
        }
    }
    Err(last)
}

/// `addrs` with the address families alternating, starting with the family
/// listed first.
fn alternate_families(addrs: &[SocketAddr]) -> Vec<SocketAddr> {
    let first_is_v4 = addrs.first().is_some_and(SocketAddr::is_ipv4);
    let (first, other): (Vec<_>, Vec<_>) = addrs
        .iter()
        .copied()
        .partition(|addr| addr.is_ipv4() == first_is_v4);
    let mut other = other.into_iter();
    let mut order: Vec<_> = first
        .into_iter()
        .flat_map(|addr| std::iter::once(addr).chain(other.next()))
        .collect();
    order.extend(other);
    order
}

/// Connects to `addr` on its own thread and sends the result to `report`.
/// Once `connect_any` has returned nobody receives, so a socket that
/// connects too late is dropped, which closes it.
fn start_attempt(
    addr: SocketAddr,
    timeout: Duration,
    connect: Connector,
    report: mpsc::Sender<Result<TcpStream, NetError>>,
) -> Result<(), NetError> {
    std::thread::Builder::new()
        .name("connect".to_string())
        .spawn(move || {
            let result = connect(&addr, timeout).map_err(|e| NetError::Connect(e.to_string()));
            let _too_late = report.send(result);
        })
        .map(drop)
        .map_err(|_| NetError::Connect("cannot start a connection attempt".to_string()))
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

    /// Races `addrs` with every attempt refused at once, and returns where
    /// and when each attempt started, in starting order.
    fn starts_when_all_refuse(addrs: &[SocketAddr]) -> Vec<(SocketAddr, Instant)> {
        let (record, starts) = mpsc::channel();
        let refuse: Connector = Arc::new(move |addr: &SocketAddr, _: Duration| {
            let _test_gone = record.send((*addr, Instant::now()));
            Err(io::ErrorKind::ConnectionRefused.into())
        });
        let _all_refused = race(addrs, &Deadline::after(Duration::from_secs(5)), refuse);
        starts.try_iter().collect()
    }

    #[test]
    fn alternates_address_families_starting_with_the_first_listed() {
        let v6 = |last| SocketAddr::from(([0x2001, 0xdb8, 0, 0, 0, 0, 0, last], 993));
        let v4 = SocketAddr::from(([192, 0, 2, 1], 993));
        let order: Vec<_> = starts_when_all_refuse(&[v6(1), v6(2), v6(3), v4])
            .into_iter()
            .map(|(addr, _)| addr)
            .collect();
        assert_eq!(order, [v6(1), v4, v6(2), v6(3)]);
    }

    #[test]
    fn a_failed_attempt_starts_the_next_at_once() {
        let addrs: Vec<_> = (1..=4)
            .map(|last| SocketAddr::from(([192, 0, 2, last], 993)))
            .collect();
        let starts = starts_when_all_refuse(&addrs);
        let spread = starts[3].1 - starts[0].1;
        assert!(
            spread < 2 * ATTEMPT_DELAY,
            "four refused attempts took {spread:?} to start"
        );
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

    #[test]
    fn when_every_attempt_fails_the_last_address_error_is_reported() {
        let fails_late = SocketAddr::from(([192, 0, 2, 1], 993));
        let closed = closed_port();
        let refused = TcpStream::connect(closed).expect_err("nothing listens");
        let connect: Connector = Arc::new(move |addr: &SocketAddr, timeout: Duration| {
            if *addr != fails_late {
                return TcpStream::connect_timeout(addr, timeout);
            }
            std::thread::sleep(2 * ATTEMPT_DELAY);
            Err(io::ErrorKind::TimedOut.into())
        });
        let deadline = Deadline::after(Duration::from_secs(2));
        let result = race(&[fails_late, closed], &deadline, connect);
        assert_eq!(result.err(), Some(NetError::Connect(refused.to_string())));
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
