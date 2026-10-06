//! One mail server connection: buffered, bounded reads and writes over the
//! plain socket (SMTP before STARTTLS) or the verified TLS stream, and the
//! transcript of what the server sent, written to stdout.

use std::io::{self, BufRead, BufReader, BufWriter, Read, Stdout, Write};
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

impl Read for Transport {
    /// A peer that resets the connection, or closes it without a TLS
    /// close_notify, ends the stream like a clean close: the IMAP and SMTP
    /// framing already catch a cut-off reply.
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let read = match self {
            Transport::Plain(sock) => sock.read(buf),
            Transport::Tls(stream) => stream.read(buf),
            Transport::Closed => Ok(0),
        };
        match read {
            Err(e) if is_closed(&e) => Ok(0),
            read => read,
        }
    }
}

impl Transport {
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
    reader: BufReader<Transport>,
    transcript: Transcript,
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
            },
        }
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
        let mut line = Vec::with_capacity(256);
        (&mut self.reader)
            .take(MAX_LINE as u64)
            .read_until(b'\n', &mut line)
            .map_err(|e| read_failed(&e))?;
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
            let available = self.reader.fill_buf().map_err(|e| read_failed(&e))?;
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
