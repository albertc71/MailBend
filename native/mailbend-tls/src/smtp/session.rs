//! The SMTP session: greeting, EHLO, mandatory STARTTLS, EHLO again, quiet
//! AUTH, then the envelope and message; the first rejection stops the run.
//! QUIT is best effort.

use std::sync::Arc;

use base64ct::{Base64, Encoding};
use rustls::ClientConfig;
use zeroize::Zeroizing;

use crate::connection::Connection;
use crate::creds::Credentials;
use crate::limits::MAX_OUTPUT;
use crate::smtp::envelope::Step;
use crate::smtp::reply::{has_auth, has_extension, parse_line};
use crate::{Exit, Outcome};

const EHLO: &[u8] = b"EHLO [127.0.0.1]\r\n";

const SERVICE_READY: u16 = 220;
const SERVICE_CLOSING: u16 = 421;
const AUTH_SUCCEEDED: u16 = 235;
const OK: u16 = 250;
const AUTH_CHALLENGE: u16 = 334;
const START_MAIL_INPUT: u16 = 354;

/// A complete reply: its code and all of its lines.
struct Reply {
    code: u16,
    lines: Vec<u8>,
}

pub fn run(
    conn: &mut Connection,
    tls: &Arc<ClientConfig>,
    host: &str,
    creds: &Credentials,
    steps: &[Step<'_>],
) -> Result<Outcome, Exit> {
    let ehlo = negotiate_tls(conn, tls, host)?;
    authenticate(conn, &ehlo, creds)?;
    let rejected_with = send_envelope(conn, steps)?;
    // After 421 the server has already closed the connection.
    if rejected_with != Some(SERVICE_CLOSING) {
        quit(conn);
    }
    Ok(match rejected_with {
        None => Outcome::Completed,
        Some(_) => Outcome::Rejected("SMTP command rejected".to_string()),
    })
}

/// Reads one (possibly multi-line) reply, copying it to the transcript. The
/// reply is bounded like the transcript, also while the transcript is
/// paused for authentication.
fn read_reply(conn: &mut Connection) -> Result<Reply, Exit> {
    let mut lines = Vec::new();
    loop {
        let line = conn
            .read_line()?
            .ok_or_else(|| Exit::protocol("connection closed while waiting for a reply"))?;
        conn.emit(&line)?;
        let parsed = parse_line(&line)?;
        if (lines.len() + line.len()) as u64 > MAX_OUTPUT {
            return Err(Exit::protocol("SMTP reply exceeds the output limit"));
        }
        lines.extend_from_slice(&line);
        if !parsed.more {
            return Ok(Reply {
                code: parsed.code,
                lines,
            });
        }
    }
}

fn reply_code(conn: &mut Connection) -> Result<u16, Exit> {
    read_reply(conn).map(|reply| reply.code)
}

/// Greeting, EHLO, STARTTLS (which the server must offer) and EHLO again
/// over TLS. Returns the second EHLO reply, which lists the AUTH
/// mechanisms.
fn negotiate_tls(
    conn: &mut Connection,
    tls: &Arc<ClientConfig>,
    host: &str,
) -> Result<Vec<u8>, Exit> {
    if reply_code(conn)? != SERVICE_READY {
        return Err(Exit::protocol("server refused the connection"));
    }
    let ehlo = hello(conn, "EHLO rejected")?;
    if !has_extension(&ehlo, b"STARTTLS") {
        return Err(Exit::connect("server does not offer STARTTLS"));
    }
    conn.write(b"STARTTLS\r\n")?;
    if reply_code(conn)? != SERVICE_READY {
        return Err(Exit::connect("STARTTLS refused"));
    }
    conn.start_tls(tls, host)?;
    hello(conn, "EHLO after STARTTLS rejected")
}

/// Sends EHLO and returns the reply's lines.
fn hello(conn: &mut Connection, rejected: &str) -> Result<Vec<u8>, Exit> {
    conn.write(EHLO)?;
    let reply = read_reply(conn)?;
    if reply.code != OK {
        return Err(Exit::protocol(rejected));
    }
    Ok(reply.lines)
}

/// AUTH PLAIN, else AUTH LOGIN, with the transcript paused.
fn authenticate(conn: &mut Connection, ehlo: &[u8], creds: &Credentials) -> Result<(), Exit> {
    conn.quietly(|conn| {
        if has_auth(ehlo, b"PLAIN") {
            auth_plain(conn, creds)?;
        } else if has_auth(ehlo, b"LOGIN") {
            auth_login(conn, creds)?;
        } else {
            return Err(Exit::auth(
                "server offers neither AUTH PLAIN nor AUTH LOGIN",
            ));
        }
        if reply_code(conn)? != AUTH_SUCCEEDED {
            return Err(Exit::auth("SMTP authentication rejected"));
        }
        Ok(())
    })
}

fn auth_plain(conn: &mut Connection, creds: &Credentials) -> Result<(), Exit> {
    // An empty authorization identity, then the user and the password.
    let mut message = Zeroizing::new(Vec::with_capacity(creds.user.len() + creds.pass.len() + 2));
    message.push(0);
    message.extend_from_slice(&creds.user);
    message.push(0);
    message.extend_from_slice(&creds.pass);
    conn.write(&base64_line(b"AUTH PLAIN ", &message)?)
}

fn auth_login(conn: &mut Connection, creds: &Credentials) -> Result<(), Exit> {
    conn.write(b"AUTH LOGIN\r\n")?;
    for secret in [&creds.user, &creds.pass] {
        if reply_code(conn)? != AUTH_CHALLENGE {
            return Err(Exit::auth("SMTP AUTH LOGIN refused"));
        }
        conn.write(&base64_line(b"", secret)?)?;
    }
    Ok(())
}

/// `prefix`, then `secret` in base64, then CRLF, in a buffer wiped on drop
/// and sized up front, so it is never reallocated (which would leave an
/// unwiped copy behind).
fn base64_line(prefix: &[u8], secret: &[u8]) -> Result<Zeroizing<Vec<u8>>, Exit> {
    let encoded_len = Base64::encoded_len(secret);
    let mut line = Zeroizing::new(vec![0u8; prefix.len() + encoded_len + 2]);
    let (head, rest) = line.split_at_mut(prefix.len());
    let (encoded, crlf) = rest.split_at_mut(encoded_len);
    head.copy_from_slice(prefix);
    Base64::encode(secret, encoded).map_err(|_| Exit::auth("cannot encode the credentials"))?;
    crlf.copy_from_slice(b"\r\n");
    Ok(line)
}

/// Sends the envelope step by step. Returns the code of the reply that
/// rejected it, if one did.
fn send_envelope(conn: &mut Connection, steps: &[Step<'_>]) -> Result<Option<u16>, Exit> {
    for step in steps {
        let code = match *step {
            Step::Command(line) => {
                conn.write(line)?;
                reply_code(conn)?
            }
            Step::Data { command, message } => {
                conn.write(command)?;
                let code = reply_code(conn)?;
                if code != START_MAIL_INPUT {
                    return Ok(Some(code));
                }
                conn.write(message)?;
                reply_code(conn)?
            }
        };
        if code / 100 != 2 {
            return Ok(Some(code));
        }
    }
    Ok(None)
}

/// QUIT is best effort, and its failure is silent: the server may already
/// have accepted the message, so a failed QUIT must not turn the outcome
/// into a transport error.
fn quit(conn: &mut Connection) {
    if conn.write(b"QUIT\r\n").is_err() {
        return;
    }
    while let Ok(Some(line)) = conn.read_line() {
        if conn.emit(&line).is_err() || !parse_line(&line).is_ok_and(|reply| reply.more) {
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::net::{TcpListener, TcpStream};

    #[test]
    fn an_endless_reply_is_refused_while_authenticating() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        let server = std::thread::spawn(move || {
            let (mut peer, _) = listener.accept().expect("accept");
            let mut line = vec![b'x'; 1 << 20];
            line[..4].copy_from_slice(b"235-");
            let end = line.len() - 2;
            line[end..].copy_from_slice(b"\r\n");
            // One continuation line past the limit, never a last line.
            for _ in 0..=(MAX_OUTPUT >> 20) {
                if peer.write_all(&line).is_err() {
                    return;
                }
            }
        });
        let mut conn = Connection::new(TcpStream::connect(addr).expect("connect"));
        let code = conn.quietly(read_reply).map(|reply| reply.code);
        assert_eq!(
            code,
            Err(Exit::protocol("SMTP reply exceeds the output limit"))
        );
        drop(conn);
        server.join().expect("server");
    }

    #[test]
    fn base64_lines_fill_their_buffer_exactly() {
        let line = base64_line(b"AUTH PLAIN ", b"\0u\0p").expect("encode");
        assert_eq!(line.as_slice(), b"AUTH PLAIN AHUAcA==\r\n");
        assert_eq!(line.capacity(), line.len());
        assert_eq!(base64_line(b"", b"").expect("encode").as_slice(), b"\r\n");
    }
}
