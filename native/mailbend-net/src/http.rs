//! Just enough HTTP/1.x to read one response on a connection the client
//! closes after it: the status line, Content-Length or chunked framing, and
//! size limits. Every malformed response is an error. Reading is linear in
//! the response size: the head and chunked framing are each scanned once.

use std::io::{ErrorKind, Read};

use crate::NetError;

/// The longest response head accepted.
pub const MAX_HEADER: usize = 16 * 1024;

/// An HTTP response: its status and its complete body.
#[derive(Debug, PartialEq, Eq)]
pub struct HttpResponse {
    pub status: u16,
    pub body: Vec<u8>,
}

/// How the body's end is found.
enum Framing {
    Length(usize),
    Chunked(Chunked),
    /// Until the server closes the connection.
    Close,
}

fn malformed() -> NetError {
    NetError::Http("malformed HTTP response".to_string())
}

fn too_long() -> NetError {
    NetError::Http("HTTP response too long".to_string())
}

/// Reads one response from `stream` (a connection the server closes after
/// it), with a body of up to `max_body` bytes.
pub fn read_response<S: Read>(stream: &mut S, max_body: usize) -> Result<HttpResponse, NetError> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 16 * 1024];
    let mut head: Option<(usize, u16, Framing)> = None;
    loop {
        let (n, eof) = match stream.read(&mut chunk) {
            Ok(0) => (0, true),
            Ok(n) => (n, false),
            // Many servers close without TLS close_notify; the response's
            // own framing decides whether it is complete.
            Err(e) if e.kind() == ErrorKind::UnexpectedEof => (0, true),
            Err(e) if matches!(e.kind(), ErrorKind::TimedOut | ErrorKind::WouldBlock) => {
                return Err(NetError::TimedOut);
            }
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(_) => return Err(NetError::Http("no HTTP response".to_string())),
        };
        let scanned = buf.len();
        buf.extend_from_slice(&chunk[..n]);
        if buf.len() > MAX_HEADER + 4 + max_body {
            return Err(too_long());
        }
        if head.is_none() {
            match find_head_end(&buf, scanned)? {
                Some(end) => {
                    let (status, framing) = parse_head(&buf[..end], max_body)?;
                    head = Some((end, status, framing));
                }
                None if eof => return Err(malformed()),
                None => continue,
            }
        }
        if let Some((end, status, framing)) = &mut head
            && let Some(body) = body_of(framing, &buf[*end..], eof, max_body)?
        {
            return Ok(HttpResponse {
                status: *status,
                body,
            });
        }
        if eof {
            return Err(malformed());
        }
    }
}

/// The offset just past the head's blank line, searching from `from` (less
/// the three bytes a split CRLFCRLF may start in).
fn find_head_end(buf: &[u8], from: usize) -> Result<Option<usize>, NetError> {
    let start = from.saturating_sub(3);
    match buf[start..].windows(4).position(|w| w == b"\r\n\r\n") {
        Some(at) if start + at <= MAX_HEADER => Ok(Some(start + at + 4)),
        Some(_) => Err(malformed()),
        None if buf.len() > MAX_HEADER + 3 => Err(malformed()),
        None => Ok(None),
    }
}

/// The complete body once it has arrived, or `Ok(None)` until then.
fn body_of(
    framing: &mut Framing,
    rest: &[u8],
    eof: bool,
    max_body: usize,
) -> Result<Option<Vec<u8>>, NetError> {
    let body = match framing {
        Framing::Length(n) => rest.get(..*n).map(<[u8]>::to_vec),
        Framing::Chunked(chunked) => chunked.advance(rest, max_body)?,
        Framing::Close if rest.len() > max_body => return Err(too_long()),
        Framing::Close => eof.then(|| rest.to_vec()),
    };
    match body {
        Some(body) => Ok(Some(body)),
        None if eof => Err(malformed()),
        None => Ok(None),
    }
}

/// The status code and body framing from the response head (ending with
/// its blank line).
fn parse_head(head: &[u8], max_body: usize) -> Result<(u16, Framing), NetError> {
    let head = std::str::from_utf8(head).map_err(|_| malformed())?;
    let head = head.strip_suffix("\r\n\r\n").ok_or_else(malformed)?;
    let mut lines = head.split("\r\n");
    let status_line = lines.next().ok_or_else(malformed)?;
    let mut parts = status_line.splitn(3, ' ');
    let version = parts.next().ok_or_else(malformed)?;
    let code = parts.next().ok_or_else(malformed)?;
    if !version.starts_with("HTTP/1.")
        || code.len() != 3
        || !code.bytes().all(|b| b.is_ascii_digit())
    {
        return Err(malformed());
    }
    let status = code.parse::<u16>().map_err(|_| malformed())?;
    let mut length = None;
    let mut chunked = false;
    for line in lines {
        let (name, value) = line.split_once(':').ok_or_else(malformed)?;
        let value = value.trim();
        if name.eq_ignore_ascii_case("content-length") {
            let n = value.parse::<usize>().map_err(|_| malformed())?;
            if n > max_body {
                return Err(too_long());
            }
            if length.is_some_and(|l| l != n) {
                return Err(malformed());
            }
            length = Some(n);
        } else if name.eq_ignore_ascii_case("transfer-encoding") {
            if !value.eq_ignore_ascii_case("chunked") {
                return Err(malformed());
            }
            chunked = true;
        }
    }
    let framing = match (chunked, length) {
        (true, _) => Framing::Chunked(Chunked::default()),
        (false, Some(n)) => Framing::Length(n),
        (false, None) => Framing::Close,
    };
    Ok((status, framing))
}

/// The longest chunk size line accepted, with any chunk extensions.
const MAX_SIZE_LINE: usize = 1024;

/// A chunked body decoded as it arrives: `at` is where the next chunk size
/// line starts in the bytes after the head.
#[derive(Default)]
struct Chunked {
    at: usize,
    body: Vec<u8>,
}

impl Chunked {
    /// Decodes the chunks complete in `rest` (all bytes after the head so
    /// far) and returns the body once its last chunk has arrived.
    fn advance(&mut self, rest: &[u8], max_body: usize) -> Result<Option<Vec<u8>>, NetError> {
        loop {
            let pending = &rest[self.at..];
            let Some(line_end) = pending.windows(2).position(|w| w == b"\r\n") else {
                // A size line is short; bounding it keeps rescans cheap.
                if pending.len() > MAX_SIZE_LINE {
                    return Err(malformed());
                }
                return Ok(None);
            };
            let size_line = std::str::from_utf8(&pending[..line_end]).map_err(|_| malformed())?;
            let size = size_line.split(';').next().unwrap_or(size_line).trim();
            let size = usize::from_str_radix(size, 16).map_err(|_| malformed())?;
            if size > max_body || self.body.len() + size > max_body {
                return Err(too_long());
            }
            let data = &pending[line_end + 2..];
            if size == 0 {
                // Trailers are not used; wait for the final CRLF.
                if !data.starts_with(b"\r\n") {
                    return Ok(None);
                }
                return Ok(Some(std::mem::take(&mut self.body)));
            }
            // The size line is rescanned while the data arrives: it is short.
            let Some(chunk) = data.get(..size + 2) else {
                return Ok(None);
            };
            if &chunk[size..] != b"\r\n" {
                return Err(malformed());
            }
            self.body.extend_from_slice(&chunk[..size]);
            self.at += line_end + 2 + size + 2;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MAX: usize = 65535;

    /// Parses `buf` as a whole response: `Ok(None)` while more bytes are
    /// needed (`eof` says the connection has ended).
    fn parse_response(
        buf: &[u8],
        eof: bool,
        max_body: usize,
    ) -> Result<Option<HttpResponse>, NetError> {
        let Some(head_end) = find_head_end(buf, 0)? else {
            return if eof { Err(malformed()) } else { Ok(None) };
        };
        let (status, mut framing) = parse_head(&buf[..head_end], max_body)?;
        body_of(&mut framing, &buf[head_end..], eof, max_body)
            .map(|body| body.map(|body| HttpResponse { status, body }))
    }

    fn body(buf: &[u8], eof: bool) -> Result<Option<Vec<u8>>, NetError> {
        parse_response(buf, eof, MAX).map(|r| r.map(|r| r.body))
    }

    /// Reads `bytes` in pieces of `step` bytes.
    struct Trickle<'a> {
        bytes: &'a [u8],
        step: usize,
    }

    impl Read for Trickle<'_> {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            let n = self.step.min(buf.len()).min(self.bytes.len());
            buf[..n].copy_from_slice(&self.bytes[..n]);
            self.bytes = &self.bytes[n..];
            Ok(n)
        }
    }

    fn read_in_steps(bytes: &[u8], step: usize) -> Result<HttpResponse, NetError> {
        read_response(&mut Trickle { bytes, step }, MAX)
    }

    #[test]
    fn content_length_frames_the_body() {
        let ok = b"HTTP/1.0 200 OK\r\nContent-Length: 3\r\n\r\nabc";
        assert_eq!(
            parse_response(ok, false, MAX),
            Ok(Some(HttpResponse {
                status: 200,
                body: b"abc".to_vec()
            }))
        );
        assert_eq!(body(&ok[..ok.len() - 1], false), Ok(None));
        assert!(body(&ok[..ok.len() - 1], true).is_err());
    }

    #[test]
    fn without_framing_the_body_ends_at_close() {
        let close = b"HTTP/1.1 200 OK\r\n\r\nxyz";
        assert_eq!(body(close, false), Ok(None));
        assert_eq!(body(close, true), Ok(Some(b"xyz".to_vec())));
    }

    #[test]
    fn chunked_bodies_are_joined() {
        let chunked =
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nab\r\n1\r\nc\r\n0\r\n\r\n";
        assert_eq!(body(chunked, false), Ok(Some(b"abc".to_vec())));
        assert_eq!(body(&chunked[..chunked.len() - 2], false), Ok(None));
    }

    #[test]
    fn error_statuses_are_returned() {
        let error = b"HTTP/1.0 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n";
        assert_eq!(
            parse_response(error, false, MAX).map(|r| r.map(|r| r.status)),
            Ok(Some(503))
        );
    }

    #[test]
    fn malformed_or_oversized_responses_are_errors() {
        for bad in [
            &b"garbage\r\n\r\n"[..],
            b"HTTP/1.1 200 OK\r\nContent-Length: 99999999\r\n\r\n",
            b"HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
            b"HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n",
            b"HTTP/2 200\r\n\r\n",
        ] {
            assert!(parse_response(bad, false, MAX).is_err());
        }
        let small = b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nabcd";
        assert!(parse_response(small, false, 3).is_err());
    }

    #[test]
    fn responses_read_in_any_pieces_are_the_same() {
        let chunked = b"HTTP/1.1 422 Unprocessable\r\nTransfer-Encoding: chunked\r\n\r\n\
                        3\r\n{\"a\r\n2\r\n\"}\r\n0\r\n\r\n";
        let framed = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi";
        let closed = b"HTTP/1.1 200 OK\r\n\r\nbye";
        for step in [1, 2, 3, 7, 4096] {
            let response = read_in_steps(chunked, step).expect("chunked");
            assert_eq!((response.status, response.body), (422, b"{\"a\"}".to_vec()));
            assert_eq!(read_in_steps(framed, step).expect("framed").body, b"hi");
            assert_eq!(read_in_steps(closed, step).expect("closed").body, b"bye");
        }
        assert!(read_in_steps(&framed[..framed.len() - 1], 5).is_err());
        assert!(read_in_steps(b"HTTP/1.1 200 OK\r\n", 5).is_err());
    }
}
