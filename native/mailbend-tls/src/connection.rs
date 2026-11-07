//! One mail server connection: buffered, bounded reads and writes over the
//! plain socket (SMTP before STARTTLS) or the verified TLS stream, and the
//! transcript of what the server sent, written to stdout.

use std::io::{self, BufRead, BufReader, BufWriter, Read, Stdout, Write};
use std::net::TcpStream;
use std::sync::Arc;
use std::time::Duration;

use mailbend_io::core_bytes::encode_bytes;
use mailbend_net::connect::{BoundedStream, Deadline};
use mailbend_net::tls::{self, TlsStream};
use rustls::ClientConfig;

use crate::Exit;
use crate::limits::{MAX_LINE, MAX_OUTPUT};

const READ_BUFFER: usize = 16 * 1024;

enum Transport {
    Plain(TcpStream),
    Tls(Box<TlsStream>),
    BoundedPlain(BoundedStream),
    BoundedTls(Box<TlsStream<BoundedStream>>),
    /// While the socket is moved between transport modes.
    Closed,
}

impl Read for Transport {
    /// A peer that resets the connection, or closes it without a TLS
    /// close_notify, ends the stream like a clean close: the IMAP and SMTP
    /// framing already catch a cut-off reply.
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let read = match self {
            Transport::Plain(sock) => sock.read(buf),
            Transport::Tls(stream) => stream.read(buf),
            Transport::BoundedPlain(sock) => sock.read(buf),
            Transport::BoundedTls(stream) => stream.read(buf),
            Transport::Closed => Ok(0),
        };
        match read {
            Err(e) if is_closed(&e) => Ok(0),
            read => read,
        }
    }
}

impl Transport {
    fn socket(&self) -> io::Result<&TcpStream> {
        match self {
            Self::Plain(sock) => Ok(sock),
            Self::Tls(stream) => Ok(stream.get_ref()),
            _ => Err(io::ErrorKind::NotConnected.into()),
        }
    }

    fn send(&mut self, bytes: &[u8]) -> io::Result<()> {
        match self {
            Transport::Plain(sock) => sock.write_all(bytes).and_then(|()| sock.flush()),
            Transport::Tls(stream) => stream.write_all(bytes).and_then(|()| stream.flush()),
            Transport::BoundedPlain(sock) => sock.write_all(bytes).and_then(|()| sock.flush()),
            Transport::BoundedTls(stream) => stream.write_all(bytes).and_then(|()| stream.flush()),
            Transport::Closed => Err(io::ErrorKind::NotConnected.into()),
        }
    }
}

/// The server's bytes on stdout, encoded for the Bend core.
struct Transcript {
    out: BufWriter<Stdout>,
    total: u64,
    encoded: Vec<u8>,
    /// Set while authenticating: those replies are consumed, never
    /// recorded, so a server that echoes the credentials cannot pass them
    /// to the core.
    quiet: bool,
    redacted: bool,
}

impl Transcript {
    fn record(&mut self, bytes: &[u8]) -> Result<(), Exit> {
        if self.quiet || self.redacted {
            return Ok(());
        }
        self.total += bytes.len() as u64;
        if self.total > MAX_OUTPUT {
            return Err(Exit::protocol("transcript exceeds the output limit"));
        }
        self.encoded.clear();
        encode_bytes(bytes, &mut self.encoded);
        // Like stdio, a closed stdout does not change the mail outcome.
        let _ignored = self.out.write_all(&self.encoded);
        Ok(())
    }
}

#[derive(Clone, Copy)]
struct Continuation {
    deadline: Deadline,
    read_timeout: Duration,
    write_timeout: Duration,
}

impl Continuation {
    fn check(&self) -> Result<(), Exit> {
        self.deadline
            .remaining()
            .map(|_| ())
            .map_err(|_| Exit::protocol("read from server timed out"))
    }
}

pub struct Connection {
    reader: BufReader<Transport>,
    transcript: Transcript,
    pub(crate) stage: &'static str,
    report_auth: bool,
    continuation: Option<Continuation>,
}

impl Connection {
    pub fn new(sock: TcpStream) -> Self {
        Connection {
            reader: BufReader::with_capacity(READ_BUFFER, Transport::Plain(sock)),
            transcript: Transcript {
                out: BufWriter::with_capacity(1 << 16, std::io::stdout()),
                total: 0,
                encoded: Vec::new(),
                quiet: false,
                redacted: false,
            },
            stage: "connect",
            report_auth: false,
            continuation: None,
        }
    }

    pub(crate) fn diagnostic(sock: TcpStream, report: bool) -> Self {
        let mut conn = Self::new(sock);
        conn.transcript.redacted = true;
        conn.report_auth = report;
        conn
    }

    pub(crate) fn report_smtp_auth(&self, ehlo: &[u8]) {
        if self.report_auth {
            print!("{}", crate::smtp::reply::auth_facts(ehlo));
        }
    }

    /// Only fixed transport facts escape a diagnostic session.
    pub(crate) fn enter_stage(&mut self, stage: &'static str) {
        if self.transcript.redacted {
            println!("{} ok", self.stage);
        }
        self.stage = stage;
    }

    /// Starts TLS on the plain socket. No bytes may be waiting: anything
    /// the server sent before the handshake would otherwise be read as if
    /// it had been protected.
    pub fn start_tls(&mut self, config: &Arc<ClientConfig>, host: &str) -> Result<(), Exit> {
        if !self.reader.buffer().is_empty() {
            return Err(Exit::protocol("server sent data before the TLS handshake"));
        }
        let Transport::Plain(sock) = std::mem::replace(self.reader.get_mut(), Transport::Closed)
        else {
            return Err(Exit::protocol("TLS already started"));
        };
        // The socket's timeouts bound the handshake.
        let stream = tls::connect(config, host, sock)?;
        *self.reader.get_mut() = Transport::Tls(Box::new(stream));
        Ok(())
    }

    pub(crate) fn begin_login_continuation(&mut self) -> Result<(), Exit> {
        if self.continuation.is_some() {
            return Ok(());
        }
        let settings = || -> io::Result<_> {
            let sock = self.reader.get_ref().socket()?;
            let read = sock.read_timeout()?.ok_or(io::ErrorKind::InvalidInput)?;
            let write = sock.write_timeout()?.ok_or(io::ErrorKind::InvalidInput)?;
            Ok((read, write))
        };
        let (read_timeout, write_timeout) =
            settings().map_err(|_| Exit::protocol("cannot bound login continuation"))?;
        let deadline = Deadline::after(read_timeout.min(write_timeout));
        let transport = std::mem::replace(self.reader.get_mut(), Transport::Closed);
        *self.reader.get_mut() = match transport {
            Transport::Plain(sock) => Transport::BoundedPlain(BoundedStream::new(sock, deadline)),
            Transport::Tls(stream) => {
                let (tls, sock) = stream.into_parts();
                Transport::BoundedTls(Box::new(TlsStream::new(
                    tls,
                    BoundedStream::new(sock, deadline),
                )))
            }
            _ => return Err(Exit::protocol("cannot bound login continuation")),
        };
        self.continuation = Some(Continuation {
            deadline,
            read_timeout,
            write_timeout,
        });
        Ok(())
    }

    pub(crate) fn finish_login_continuation(&mut self) -> Result<(), Exit> {
        let Some(continuation) = self.continuation.take() else {
            return Ok(());
        };
        let transport = std::mem::replace(self.reader.get_mut(), Transport::Closed);
        let restored = match transport {
            Transport::BoundedPlain(sock) => Transport::Plain(sock.into_inner()),
            Transport::BoundedTls(stream) => {
                let (tls, sock) = stream.into_parts();
                Transport::Tls(Box::new(TlsStream::new(tls, sock.into_inner())))
            }
            _ => return Err(Exit::protocol("cannot restore login connection")),
        };
        let restore = || -> io::Result<()> {
            let sock = restored.socket()?;
            sock.set_read_timeout(Some(continuation.read_timeout))?;
            sock.set_write_timeout(Some(continuation.write_timeout))
        };
        restore().map_err(|_| Exit::protocol("cannot restore login connection"))?;
        *self.reader.get_mut() = restored;
        Ok(())
    }

    /// Copies server bytes to the transcript.
    pub fn emit(&mut self, bytes: &[u8]) -> Result<(), Exit> {
        self.transcript.record(bytes)
    }

    /// Runs `f` with the transcript paused, for the authentication
    /// exchange.
    pub fn quietly<T>(&mut self, f: impl FnOnce(&mut Self) -> Result<T, Exit>) -> Result<T, Exit> {
        self.transcript.quiet = true;
        let result = f(self);
        self.transcript.quiet = false;
        result
    }

    pub fn flush_transcript(&mut self) {
        let _ignored = self.transcript.out.flush();
    }

    /// One line including its LF, or `None` at the end of the stream.
    pub fn read_line(&mut self) -> Result<Option<Vec<u8>>, Exit> {
        if let Some(continuation) = self.continuation {
            continuation.check()?;
        }
        let mut line = Vec::with_capacity(256);
        (&mut self.reader)
            .take(MAX_LINE as u64)
            .read_until(b'\n', &mut line)
            .map_err(|e| read_failed(&e))?;
        if let Some(continuation) = self.continuation {
            continuation.check()?;
        }
        if line.len() >= MAX_LINE {
            return Err(Exit::protocol("server line exceeds the line limit"));
        }
        match line.last() {
            None => Ok(None),
            Some(b'\n') => Ok(Some(line)),
            Some(_) => Err(Exit::protocol("connection closed mid-line")),
        }
    }

    /// Copies exactly `n` server bytes (an IMAP literal) to the transcript.
    pub fn pass_bytes(&mut self, mut n: u64) -> Result<(), Exit> {
        while n > 0 {
            if let Some(continuation) = self.continuation {
                continuation.check()?;
            }
            let available = self.reader.fill_buf().map_err(|e| read_failed(&e))?;
            if let Some(continuation) = self.continuation {
                continuation.check()?;
            }
            if available.is_empty() {
                return Err(Exit::protocol("connection closed inside a literal"));
            }
            let take = available
                .len()
                .min(usize::try_from(n).unwrap_or(usize::MAX));
            self.transcript.record(&available[..take])?;
            self.reader.consume(take);
            n -= take as u64;
        }
        Ok(())
    }

    pub fn write(&mut self, bytes: &[u8]) -> Result<(), Exit> {
        self.reader
            .get_mut()
            .send(bytes)
            .map_err(|_| Exit::protocol("write to server failed or timed out"))
    }
}

fn is_closed(e: &io::Error) -> bool {
    matches!(
        e.kind(),
        io::ErrorKind::UnexpectedEof | io::ErrorKind::ConnectionReset
    )
}

fn read_failed(e: &io::Error) -> Exit {
    if matches!(
        e.kind(),
        io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
    ) {
        Exit::protocol("read from server timed out")
    } else {
        Exit::protocol("read from server failed")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::thread;

    fn pair() -> (TcpStream, TcpStream) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let client = TcpStream::connect(listener.local_addr().expect("address")).expect("connect");
        let (server, _) = listener.accept().expect("accept");
        (client, server)
    }

    #[test]
    fn login_continuation_requires_both_socket_timeouts() {
        for (read, write) in [(None, None), (Some(300), None), (None, Some(300))] {
            let (socket, _peer) = pair();
            socket
                .set_read_timeout(read.map(Duration::from_millis))
                .expect("read timeout");
            socket
                .set_write_timeout(write.map(Duration::from_millis))
                .expect("write timeout");
            let mut conn = Connection::new(socket);
            assert_eq!(
                conn.begin_login_continuation(),
                Err(Exit::protocol("cannot bound login continuation"))
            );
        }
    }

    #[test]
    fn login_continuation_uses_the_shorter_timeout_and_restores_both() {
        for (read, write) in [(300, 700), (700, 300)] {
            let (socket, _peer) = pair();
            let observer = socket.try_clone().expect("observe socket options");
            let read = Duration::from_millis(read);
            let write = Duration::from_millis(write);
            socket.set_read_timeout(Some(read)).expect("read timeout");
            socket
                .set_write_timeout(Some(write))
                .expect("write timeout");
            let mut conn = Connection::new(socket);
            conn.begin_login_continuation().expect("bounded");
            conn.write(b"x").expect("bounded write");
            for timeout in [observer.read_timeout(), observer.write_timeout()] {
                assert!(timeout.expect("timeout").expect("finite") <= Duration::from_millis(300));
            }
            conn.finish_login_continuation().expect("restored");
            assert_eq!(observer.read_timeout().expect("read timeout"), Some(read));
            assert_eq!(
                observer.write_timeout().expect("write timeout"),
                Some(write)
            );
            thread::sleep(Duration::from_millis(350));
            conn.write(b"after").expect("ordinary write after deadline");
        }
    }

    #[test]
    fn buffered_plain_lines_and_literals_cannot_outlive_the_deadline() {
        for literal in [false, true] {
            let (socket, mut peer) = pair();
            socket
                .set_read_timeout(Some(Duration::from_millis(300)))
                .expect("read timeout");
            socket
                .set_write_timeout(Some(Duration::from_millis(300)))
                .expect("write timeout");
            peer.write_all(b"first\r\nsecond\r\n")
                .expect("coalesced input");
            let mut conn = Connection::new(socket);
            assert_eq!(
                conn.read_line().expect("first line"),
                Some(b"first\r\n".to_vec())
            );
            conn.begin_login_continuation().expect("bounded");
            thread::sleep(Duration::from_millis(350));
            let result = if literal {
                conn.pass_bytes(6)
            } else {
                conn.read_line().map(|_| ())
            };
            assert_eq!(result, Err(Exit::protocol("read from server timed out")));
        }
    }
}
