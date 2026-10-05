//! TCP connections under one deadline: name resolution (bounded even for
//! the system resolver) and sequential fallback across addresses.

use std::io::{self, Read, Write};
use std::net::{IpAddr, SocketAddr, TcpStream, ToSocketAddrs};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use crate::NetError;

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
        Err(_) => Err(NetError::Dns(format!("resolving {host} timed out"))),
    }
}

/// Connects to the first address that accepts, in order, giving each
/// attempt an equal share of the time left.
pub fn connect_any(addrs: &[SocketAddr], deadline: &Deadline) -> Result<TcpStream, NetError> {
    let mut last = NetError::Connect("no addresses".to_string());
    for (i, addr) in addrs.iter().enumerate() {
        let attempts_left = u32::try_from(addrs.len() - i).unwrap_or(u32::MAX);
        let share = deadline.remaining()? / attempts_left;
        match TcpStream::connect_timeout(addr, share.max(Duration::from_millis(1))) {
            Ok(sock) => return Ok(sock),
            Err(e) => last = NetError::Connect(e.to_string()),
        }
    }
    Err(last)
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
