//! Just enough HTTP/1.x to read a DoH resolver's response: the status line,
//! Content-Length or chunked framing, and size limits. Every malformed
//! response is an error.

use crate::NetError;

/// The longest response head accepted.
pub const MAX_HEADER: usize = 16 * 1024;
/// No DNS answer MailBend asks for comes near this; larger bodies are
/// refused.
pub const MAX_BODY: usize = 65535;

/// An HTTP response: its status and its complete body.
#[derive(Debug, PartialEq, Eq)]
pub struct HttpResponse {
    pub status: u16,
    pub body: Vec<u8>,
}

/// How the body's end is found.
enum Framing {
    Length(usize),
    Chunked,
    /// Until the server closes the connection.
    Close,
}

fn malformed() -> NetError {
    NetError::Doh("malformed HTTP response from the resolver".to_string())
}

/// Parses `buf` as an HTTP/1.x response. Returns `Ok(None)` while more
/// bytes are needed (`eof` says the connection has ended), and an error for
/// a malformed or oversized response.
pub fn parse_response(buf: &[u8], eof: bool) -> Result<Option<HttpResponse>, NetError> {
    let Some(head_end) = buf.windows(4).position(|w| w == b"\r\n\r\n") else {
        if buf.len() > MAX_HEADER || eof {
            return Err(malformed());
        }
        return Ok(None);
    };
    if head_end > MAX_HEADER {
        return Err(malformed());
    }
    let head = std::str::from_utf8(&buf[..head_end]).map_err(|_| malformed())?;
    let (status, framing) = parse_head(head)?;
    let rest = &buf[head_end + 4..];
    let body = match framing {
        Framing::Chunked => decode_chunked(rest)?,
        Framing::Length(n) => rest.get(..n).map(<[u8]>::to_vec),
        Framing::Close => eof.then(|| rest.to_vec()),
    };
    match body {
        Some(body) if body.len() <= MAX_BODY => Ok(Some(HttpResponse { status, body })),
        Some(_) => Err(malformed()),
        None if eof => Err(malformed()),
        None => Ok(None),
    }
}

/// The status code and body framing from the response head.
fn parse_head(head: &str) -> Result<(u16, Framing), NetError> {
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
            if n > MAX_BODY || length.is_some_and(|l| l != n) {
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
        (true, _) => Framing::Chunked,
        (false, Some(n)) => Framing::Length(n),
        (false, None) => Framing::Close,
    };
    Ok((status, framing))
}

/// A chunked body, or `Ok(None)` until its last chunk has arrived.
fn decode_chunked(mut rest: &[u8]) -> Result<Option<Vec<u8>>, NetError> {
    let mut body = Vec::new();
    loop {
        let Some(line_end) = rest.windows(2).position(|w| w == b"\r\n") else {
            return Ok(None);
        };
        let size_line = std::str::from_utf8(&rest[..line_end]).map_err(|_| malformed())?;
        let size = size_line.split(';').next().unwrap_or(size_line).trim();
        let size = usize::from_str_radix(size, 16).map_err(|_| malformed())?;
        if size > MAX_BODY || body.len() + size > MAX_BODY {
            return Err(malformed());
        }
        rest = &rest[line_end + 2..];
        if size == 0 {
            // Trailers are not used by resolvers; wait for the final CRLF.
            return Ok(rest.windows(2).any(|w| w == b"\r\n").then_some(body));
        }
        let Some(chunk) = rest.get(..size + 2) else {
            return Ok(None);
        };
        if &chunk[size..] != b"\r\n" {
            return Err(malformed());
        }
        body.extend_from_slice(&chunk[..size]);
        rest = &rest[size + 2..];
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn body(buf: &[u8], eof: bool) -> Result<Option<Vec<u8>>, NetError> {
        parse_response(buf, eof).map(|r| r.map(|r| r.body))
    }

    #[test]
    fn content_length_frames_the_body() {
        let ok = b"HTTP/1.0 200 OK\r\nContent-Length: 3\r\n\r\nabc";
        assert_eq!(
            parse_response(ok, false),
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
            parse_response(error, false).map(|r| r.map(|r| r.status)),
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
            assert!(parse_response(bad, false).is_err());
        }
    }
}
