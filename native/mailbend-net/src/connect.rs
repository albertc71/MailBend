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
    let (report, results) = mpsc::channel();
    let mut last = NetError::Connect("no addresses".to_string());
    for addr in alternate_families(addrs) {
        let Ok(timeout) = deadline.remaining() else {
            last = NetError::TimedOut;
            break;
        };
        if let Err(e) = start_attempt(addr, timeout, report.clone()) {
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
    report: mpsc::Sender<Result<TcpStream, NetError>>,
) -> Result<(), NetError> {
    std::thread::Builder::new()
        .name("connect".to_string())
        .spawn(move || {
            let result = TcpStream::connect_timeout(&addr, timeout)
                .map_err(|e| NetError::Connect(e.to_string()));
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

    /// A loopback listener that never answers, like a black-holed route:
    /// Linux drops a SYN while the accept queue is full, so the queue is
    /// filled first. Returns how many connections wait in the queue.
    fn silent_listener() -> (TcpListener, SocketAddr, usize) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        let mut queued = 0;
        loop {
            match TcpStream::connect_timeout(&addr, Duration::from_millis(250)) {
                Ok(_closed_at_once) => queued += 1,
                Err(e) => {
                    assert_eq!(e.kind(), io::ErrorKind::TimedOut, "a full queue drops SYNs");
                    return (listener, addr, queued);
                }
            }
        }
    }

    #[test]
    fn races_past_a_silent_address_and_closes_the_losing_socket() {
        let (silent, silent_addr, queued) = silent_listener();
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let good = listener.local_addr().expect("addr");
        let started = Instant::now();
        let deadline = Deadline::after(Duration::from_secs(5));
        let sock = connect_any(&[silent_addr, good], &deadline).expect("connect");
        assert_eq!(sock.peer_addr().expect("peer"), good);
        assert!(started.elapsed() < Duration::from_secs(1));

        // Once the queue drains, a connection that the losing attempt
        // completes must arrive already closed, like the queued ones.
        silent.set_nonblocking(true).expect("nonblocking");
        let mut accepted = 0;
        while accepted <= queued && deadline.remaining().is_ok() {
            match silent.accept() {
                Ok((mut peer, _)) => {
                    accepted += 1;
                    peer.set_read_timeout(Some(Duration::from_secs(1)))
                        .expect("timeout");
                    assert_eq!(peer.read(&mut [0; 1]).expect("closed, not kept open"), 0);
                }
                Err(_) => std::thread::sleep(Duration::from_millis(10)),
            }
        }
    }

    #[test]
    fn alternates_address_families() {
        let (_silent, silent, _) = silent_listener();
        let v4 = TcpListener::bind("127.0.0.1:0").expect("bind");
        let v6 = TcpListener::bind("[::1]:0").expect("bind the IPv6 loopback");
        let addrs = [
            silent,
            v4.local_addr().expect("addr"),
            v6.local_addr().expect("addr"),
        ];
        let deadline = Deadline::after(Duration::from_secs(5));
        let sock = connect_any(&addrs, &deadline).expect("connect");
        assert_eq!(sock.peer_addr().expect("peer"), addrs[2]);
    }

    #[test]
    fn an_address_that_never_answers_fails_at_the_deadline() {
        let (_silent, silent, _) = silent_listener();
        let started = Instant::now();
        let result = connect_any(&[silent], &Deadline::after(Duration::from_millis(300)));
        assert!(matches!(result, Err(NetError::Connect(_))));
        let waited = started.elapsed();
        assert!((Duration::from_millis(300)..Duration::from_secs(1)).contains(&waited));
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
