//! One mail server connection: buffered, bounded reads and writes over the
//! plain socket (SMTP before STARTTLS) or the verified TLS stream, and the
//! transcript of what the server sent, written to stdout.

use std::io::{self, BufWriter, Read, Stdout, Write};
use std::net::TcpStream;
use std::sync::Arc;

use mailbend_io::transcript::encode_bytes;
use mailbend_net::tls::{self, TlsStream};
use rustls::ClientConfig;

use crate::Exit;
use crate::limits::{MAX_LINE, MAX_OUTPUT};

const READ_BUFFER: usize = 16 * 1024;

enum Transport {
    Plain(TcpStream),
    Tls(Box<TlsStream>),
    /// Only while the plain socket is handed to the TLS handshake.
    Closed,
}

impl Transport {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self {
            Transport::Plain(sock) => sock.read(buf),
            Transport::Tls(stream) => stream.read(buf),
            Transport::Closed => Ok(0),
        }
    }

    fn send(&mut self, bytes: &[u8]) -> io::Result<()> {
        match self {
            Transport::Plain(sock) => sock.write_all(bytes).and_then(|()| sock.flush()),
            Transport::Tls(stream) => stream.write_all(bytes).and_then(|()| stream.flush()),
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
}

impl Transcript {
    fn record(&mut self, bytes: &[u8]) -> Result<(), Exit> {
        if self.quiet {
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

pub struct Connection {
    transport: Transport,
    buf: Box<[u8]>,
    /// The unread bytes are `buf[pos..len]`.
    pos: usize,
    len: usize,
    transcript: Transcript,
}

impl Connection {
    pub fn new(sock: TcpStream) -> Self {
        Connection {
            transport: Transport::Plain(sock),
            buf: vec![0; READ_BUFFER].into_boxed_slice(),
            pos: 0,
            len: 0,
            transcript: Transcript {
                out: BufWriter::with_capacity(1 << 16, std::io::stdout()),
                total: 0,
                encoded: Vec::new(),
                quiet: false,
            },
        }
    }

    /// Starts TLS on the plain socket. No bytes may be waiting: anything
    /// the server sent before the handshake would otherwise be read as if
    /// it had been protected.
    pub fn start_tls(&mut self, config: &Arc<ClientConfig>, host: &str) -> Result<(), Exit> {
        if self.pos != self.len {
            return Err(Exit::protocol("server sent data before the TLS handshake"));
        }
        let Transport::Plain(sock) = std::mem::replace(&mut self.transport, Transport::Closed)
        else {
            return Err(Exit::protocol("TLS already started"));
        };
        // The socket's timeouts bound the handshake.
        let stream = tls::connect(config, host, sock)?;
        self.transport = Transport::Tls(Box::new(stream));
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

    /// Whether unread bytes are buffered, reading more if none are. False
    /// at the end of the stream, on a timeout or on a read error.
    fn fill(&mut self) -> bool {
        if self.pos < self.len {
            return true;
        }
        match self.transport.read(&mut self.buf) {
            Ok(n) if n > 0 => {
                (self.pos, self.len) = (0, n);
                true
            }
            _ => false,
        }
    }

    /// One line including its LF, or `None` at the end of the stream.
    pub fn read_line(&mut self) -> Result<Option<Vec<u8>>, Exit> {
        let mut line = Vec::with_capacity(256);
        loop {
            if !self.fill() {
                if line.is_empty() {
                    return Ok(None);
                }
                return Err(Exit::protocol(
                    "connection closed mid-line or read timed out",
                ));
            }
            let available = &self.buf[self.pos..self.len];
            let (take, complete) = match available.iter().position(|&b| b == b'\n') {
                Some(i) => (i + 1, true),
                None => (available.len(), false),
            };
            if line.len() + take >= MAX_LINE {
                return Err(Exit::protocol("server line exceeds the line limit"));
            }
            line.extend_from_slice(&available[..take]);
            self.pos += take;
            if complete {
                return Ok(Some(line));
            }
        }
    }

    /// Copies exactly `n` server bytes (an IMAP literal) to the transcript.
    pub fn pass_bytes(&mut self, mut n: u64) -> Result<(), Exit> {
        while n > 0 {
            if !self.fill() {
                return Err(Exit::protocol(
                    "connection closed inside a literal or read timed out",
                ));
            }
            let take = (self.len - self.pos).min(usize::try_from(n).unwrap_or(usize::MAX));
            self.transcript
                .record(&self.buf[self.pos..self.pos + take])?;
            self.pos += take;
            n -= take as u64;
        }
        Ok(())
    }

    pub fn write(&mut self, bytes: &[u8]) -> Result<(), Exit> {
        self.transport
            .send(bytes)
            .map_err(|_| Exit::protocol("write to server failed or timed out"))
    }
}
