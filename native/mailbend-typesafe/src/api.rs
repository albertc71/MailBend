//! The one request this helper makes: the core's JSON, POSTed to TypeSafe's
//! fixed endpoint over verified TLS. Host and path are constants; the route
//! (proxy, DNS-over-HTTPS or system DNS) never changes the TLS identity.
//! Overload and timeouts are retried a bounded number of times, unless the
//! core asks for a single attempt.

use std::io::{self, Write};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use mailbend_net::NetError;
use mailbend_net::connect::{BoundedStream, Deadline, connect_any, resolve_system};
use mailbend_net::http::{HttpResponse, read_response};
use mailbend_net::tls;
use rustls::{ClientConfig, ClientConnection, StreamOwned};
use zeroize::Zeroizing;

use crate::exit::{Exit, Failure};
use crate::settings::{HOST, PATH, PORT, Settings};
/// TypeSafe's answers are a few kilobytes per question; this bounds them.
const MAX_RESPONSE: usize = 4 * 1024 * 1024;
/// The waits before the second and third attempts (at most two retries).
const BACKOFF: [Duration; 2] = [Duration::from_secs(1), Duration::from_secs(2)];
/// Shown instead of the key wherever an answer repeats it.
const REDACTED: &[u8] = b"[redacted]";

type ApiStream = StreamOwned<ClientConnection, BoundedStream>;

/// How many attempts the core allows: the Bend core chooses, and the
/// helper only follows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Attempts {
    /// One attempt: the core would rather go on unchecked than wait.
    Once,
    /// Up to two retries after an overload or a timeout, with `BACKOFF`.
    Retried,
}

impl Attempts {
    /// The waits before each further attempt.
    fn waits(self) -> &'static [Duration] {
        match self {
            Attempts::Once => &[],
            Attempts::Retried => &BACKOFF,
        }
    }

    /// How a failure that may be passing is described: after the retries,
    /// or after the one attempt.
    fn after(self) -> &'static str {
        match self {
            Attempts::Once => "after one attempt",
            Attempts::Retried => "after retries",
        }
    }
}

/// What an attempt's answer means.
#[derive(Debug, PartialEq, Eq)]
enum Verdict {
    Answered,
    /// Overloaded or briefly unavailable: worth another attempt.
    Retry,
    Failed(Failure),
}

fn verdict(status: u16) -> Verdict {
    match status {
        200..=299 => Verdict::Answered,
        401 | 403 => Verdict::Failed(Failure::KeyRejected),
        400 | 413 | 422 => Verdict::Failed(Failure::Refused),
        429 | 500..=599 => Verdict::Retry,
        _ => Verdict::Failed(Failure::Unexpected),
    }
}

/// Sends `request` with `key`, retrying overload and timeouts as `attempts`
/// allows, and returns the answer's body with any copy of the key redacted.
/// A refusal's body is returned too (in the error's place on stdout), as it
/// holds TypeSafe's reason.
pub fn ask(
    settings: &Settings,
    key: &[u8],
    request: &[u8],
    attempts: Attempts,
) -> Result<Vec<u8>, (Exit, Vec<u8>)> {
    let no_body = |exit| (exit, Vec::new());
    let config = tls::client_config(settings.ca_file.as_deref())
        .map_err(|e| no_body(Exit::new(Failure::Connect, e.to_string())))?;
    let mut waits = attempts.waits().iter();
    loop {
        let result = attempt(settings, &config, key, request);
        let retry = match &result {
            Ok(response) => verdict(response.status) == Verdict::Retry,
            Err(error) => *error == NetError::TimedOut,
        };
        if retry && let Some(wait) = waits.next() {
            std::thread::sleep(*wait);
            continue;
        }
        let response = result.map_err(|e| no_body(network_failure(settings, &e, attempts)))?;
        let mut body = redact_key(&response.body, key);
        let failure = match verdict(response.status) {
            Verdict::Answered if std::str::from_utf8(&body).is_ok() => return Ok(body),
            Verdict::Answered => {
                return Err(no_body(Exit::new(
                    Failure::Unexpected,
                    "TypeSafe's answer is not UTF-8",
                )));
            }
            Verdict::Retry => Failure::Unavailable,
            Verdict::Failed(failure) => failure,
        };
        // A refusal's reason is passed on as text, whatever its bytes.
        body = String::from_utf8_lossy(&body).into_owned().into_bytes();
        let status = response.status;
        let message = match failure {
            Failure::KeyRejected => format!("TypeSafe rejected the key (HTTP {status})"),
            Failure::Refused => format!("TypeSafe refused the request (HTTP {status})"),
            Failure::Unavailable => format!(
                "TypeSafe is overloaded or unavailable (HTTP {status}), {}",
                attempts.after()
            ),
            _ => format!("unexpected answer from TypeSafe (HTTP {status})"),
        };
        return Err((Exit::new(failure, message), body));
    }
}

/// Why no answer arrived, as an exit: a timeout (after the attempts
/// allowed), a malformed answer, or no connection.
fn network_failure(settings: &Settings, error: &NetError, attempts: Attempts) -> Exit {
    match error {
        NetError::TimedOut => Exit::new(
            Failure::Unavailable,
            format!("TypeSafe timed out, {}", attempts.after()),
        ),
        NetError::Http(message) => {
            Exit::new(Failure::Unexpected, format!("{message} from TypeSafe"))
        }
        _ => Exit::new(
            Failure::Connect,
            format!("cannot reach {HOST} ({}; {error})", route_name(settings)),
        ),
    }
}

fn route_name(settings: &Settings) -> &'static str {
    match (&settings.proxy, &settings.doh) {
        (Some(_), _) => "HTTPS proxy",
        (None, Some(_)) => "DNS-over-HTTPS",
        (None, None) => "system DNS",
    }
}

/// One request and its answer, within one deadline.
fn attempt(
    settings: &Settings,
    config: &Arc<ClientConfig>,
    key: &[u8],
    request: &[u8],
) -> Result<HttpResponse, NetError> {
    let deadline = Deadline::after(settings.timeout);
    let mut stream = tls::connect(config, HOST, socket(settings, config, &deadline)?)?;
    send(&mut stream, key, request).map_err(|e| match e.kind() {
        io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock => NetError::TimedOut,
        _ => NetError::Connect("the connection to TypeSafe failed".to_string()),
    })?;
    read_response(&mut stream, MAX_RESPONSE)
}

/// A connection to TypeSafe: through the proxy (which resolves the name),
/// else to the addresses DNS-over-HTTPS or system DNS gives.
fn socket(
    settings: &Settings,
    config: &Arc<ClientConfig>,
    deadline: &Deadline,
) -> Result<BoundedStream, NetError> {
    if let Some(proxy) = &settings.proxy {
        return proxy.tunnel(HOST, PORT, deadline);
    }
    let addrs: Vec<SocketAddr> = match &settings.doh {
        Some(resolver) => resolver
            .resolve(config, HOST, deadline)?
            .into_iter()
            .map(|ip| SocketAddr::new(ip, PORT))
            .collect(),
        None => resolve_system(HOST, PORT, deadline)?,
    };
    Ok(BoundedStream::new(
        connect_any(&addrs, deadline)?,
        *deadline,
    ))
}

/// Writes the request. The head holds the key, so it is built in a buffer
/// wiped on drop, never in a formatted string.
fn send(stream: &mut ApiStream, key: &[u8], request: &[u8]) -> io::Result<()> {
    let mut head = Zeroizing::new(Vec::with_capacity(256 + key.len()));
    head.extend_from_slice(format!("POST {PATH} HTTP/1.1\r\nHost: {HOST}\r\n").as_bytes());
    head.extend_from_slice(b"Authorization: Bearer ");
    head.extend_from_slice(key);
    head.extend_from_slice(
        format!(
            "\r\nContent-Type: application/json\r\nAccept: application/json\r\n\
             Content-Length: {}\r\nUser-Agent: mailbend\r\nConnection: close\r\n\r\n",
            request.len()
        )
        .as_bytes(),
    );
    stream.write_all(&head)?;
    stream.write_all(request)?;
    stream.flush()
}

/// `body` with every copy of `key` redacted, also as a JSON answer may spell
/// it: with `\/` for each `/`, the only character of a Bearer token that
/// JSON encoders escape (the core decodes the answer, which would restore
/// the key).
fn redact_key(body: &[u8], key: &[u8]) -> Vec<u8> {
    let raw = redact(body, key);
    if !key.contains(&b'/') {
        return raw;
    }
    let mut escaped = Zeroizing::new(Vec::with_capacity(2 * key.len()));
    for &b in key {
        if b == b'/' {
            escaped.push(b'\\');
        }
        escaped.push(b);
    }
    redact(&raw, &escaped)
}

/// `body` with every occurrence of `key` replaced, in one linear pass
/// (Knuth-Morris-Pratt), so an answer cannot hand the key back.
fn redact(body: &[u8], key: &[u8]) -> Vec<u8> {
    if key.is_empty() {
        return body.to_vec();
    }
    // fallback[i]: the length of the longest proper border of key[..=i].
    let mut fallback = vec![0usize; key.len()];
    let mut k = 0;
    for i in 1..key.len() {
        while k > 0 && key[i] != key[k] {
            k = fallback[k - 1];
        }
        if key[i] == key[k] {
            k += 1;
        }
        fallback[i] = k;
    }
    let mut out = Vec::with_capacity(body.len());
    let mut matched = 0;
    for &b in body {
        out.push(b);
        while matched > 0 && b != key[matched] {
            matched = fallback[matched - 1];
        }
        if b == key[matched] {
            matched += 1;
        }
        if matched == key.len() {
            out.truncate(out.len() - key.len());
            out.extend_from_slice(REDACTED);
            matched = 0;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn statuses_map_to_the_documented_exits() {
        assert_eq!(verdict(200), Verdict::Answered);
        assert_eq!(verdict(401), Verdict::Failed(Failure::KeyRejected));
        assert_eq!(verdict(403), Verdict::Failed(Failure::KeyRejected));
        assert_eq!(verdict(422), Verdict::Failed(Failure::Refused));
        assert_eq!(verdict(400), Verdict::Failed(Failure::Refused));
        assert_eq!(verdict(429), Verdict::Retry);
        assert_eq!(verdict(529), Verdict::Retry);
        assert_eq!(verdict(503), Verdict::Retry);
        assert_eq!(verdict(404), Verdict::Failed(Failure::Unexpected));
        assert_eq!(verdict(301), Verdict::Failed(Failure::Unexpected));
    }

    #[test]
    fn a_single_attempt_never_waits_to_retry() {
        assert!(Attempts::Once.waits().is_empty());
        assert_eq!(Attempts::Retried.waits(), &BACKOFF);
        assert_eq!(Attempts::Once.after(), "after one attempt");
        assert_eq!(Attempts::Retried.after(), "after retries");
    }

    #[test]
    fn every_copy_of_the_key_is_redacted() {
        let key = b"ts_live_abcabd";
        let body = b"{\"detail\":\"bad key ts_live_abcabd\",\"echo\":\"Bearer ts_live_abcabd\"}";
        let redacted = redact(body, key);
        assert_eq!(
            redacted,
            b"{\"detail\":\"bad key [redacted]\",\"echo\":\"Bearer [redacted]\"}".to_vec()
        );
        // Overlapping prefixes: the matcher must not skip the real copy.
        assert_eq!(redact(b"aaab", b"aab"), b"a[redacted]".to_vec());
        assert_eq!(redact(b"abababc", b"ababc"), b"ab[redacted]".to_vec());
        assert_eq!(redact(b"no key here", key), b"no key here".to_vec());
    }

    #[test]
    fn the_json_spelling_of_a_slash_is_redacted_too() {
        let key = b"ts/key/0123";
        let body = br#"{"detail":"bad key ts\/key\/0123 or ts/key/0123"}"#;
        assert_eq!(
            redact_key(body, key),
            br#"{"detail":"bad key [redacted] or [redacted]"}"#.to_vec()
        );
        assert_eq!(redact_key(b"ts_key", b"ts_key"), b"[redacted]".to_vec());
    }
}
