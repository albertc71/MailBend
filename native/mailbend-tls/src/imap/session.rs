//! The IMAP session: TLS from the first byte, LOGIN, then the script's
//! commands one at a time, each waiting for its tagged answer; the first
//! rejection stops the run. LOGOUT is best effort.

use std::sync::Arc;

use rustls::ClientConfig;
use zeroize::Zeroizing;

use crate::connection::Connection;
use crate::creds::Credentials;
use crate::imap::response::{
    Greeting, Status, greeting, is_continuation, is_untagged, tagged_status,
};
use crate::imap::script::{Command, Expect};
use crate::imap::{LOGIN_TAG, LOGOUT_TAG, literal_len, push_quoted};
use crate::{Exit, Outcome};

/// What waiting for a command's answer ended with.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Answer {
    Tagged(Status),
    /// A `+` continuation request, when one was wanted.
    Continue,
    /// The server closed the connection.
    Closed,
}

/// The answer, and whether an untagged response met the command's
/// directive on the way.
struct Reply {
    answer: Answer,
    expectation_met: bool,
}

pub fn run(
    conn: &mut Connection,
    tls: &Arc<ClientConfig>,
    host: &str,
    creds: &Credentials,
    commands: &[Command<'_>],
) -> Result<Outcome, Exit> {
    conn.start_tls(tls, host)?;
    let first = conn
        .read_line()?
        .ok_or_else(|| Exit::protocol("no greeting"))?;
    conn.emit(&first)?;
    match greeting(&first) {
        Some(Greeting::Ok) => login(conn, creds)?,
        Some(Greeting::Preauth) => {}
        None => return Err(Exit::protocol("server refused the connection")),
    }
    let outcome = run_commands(conn, commands)?;
    logout(conn);
    Ok(outcome)
}

fn login(conn: &mut Connection, creds: &Credentials) -> Result<(), Exit> {
    conn.write(&login_command(creds))?;
    let reply = conn.quietly(|conn| wait(conn, LOGIN_TAG, false, None))?;
    match reply.answer {
        Answer::Tagged(Status::Ok) => Ok(()),
        Answer::Closed => Err(Exit::protocol("server closed the connection during login")),
        Answer::Tagged(_) | Answer::Continue => Err(Exit::auth("IMAP login rejected")),
    }
}

/// `L LOGIN "user" "password"` in a buffer wiped on drop. Its capacity
/// covers every byte being escaped, so it is never reallocated (which would
/// leave an unwiped copy behind).
fn login_command(creds: &Credentials) -> Zeroizing<Vec<u8>> {
    let worst_case = 32 + 2 * (creds.user.len() + creds.pass.len());
    let mut command = Zeroizing::new(Vec::with_capacity(worst_case));
    command.extend_from_slice(LOGIN_TAG);
    command.extend_from_slice(b" LOGIN ");
    push_quoted(&mut command, &creds.user);
    command.push(b' ');
    push_quoted(&mut command, &creds.pass);
    command.extend_from_slice(b"\r\n");
    command
}

/// Runs the commands until one is rejected or misses its directive.
fn run_commands(conn: &mut Connection, commands: &[Command<'_>]) -> Result<Outcome, Exit> {
    for command in commands {
        let reply = send_command(conn, command)?;
        let tag = String::from_utf8_lossy(command.tag);
        match reply.answer {
            Answer::Tagged(Status::Ok) => {}
            Answer::Closed => return Err(Exit::protocol("server closed the connection")),
            Answer::Tagged(_) | Answer::Continue => {
                return Ok(Outcome::Rejected(format!(
                    "command {tag} rejected; later commands skipped"
                )));
            }
        }
        if let Some(expect) = command.expect.as_ref().filter(|_| !reply.expectation_met) {
            return Ok(Outcome::Rejected(format!(
                "command {tag} lacked the expected response \"{}\"; later commands skipped",
                String::from_utf8_lossy(expect.text())
            )));
        }
    }
    Ok(Outcome::Completed)
}

/// Sends one command. Each literal is sent only once the server asks for
/// it; a refusal ends the command early.
fn send_command(conn: &mut Connection, command: &Command<'_>) -> Result<Reply, Exit> {
    let expect = command.expect.as_ref();
    let mut expectation_met = false;
    for literal in &command.literals {
        conn.write(literal.line)?;
        let reply = wait(conn, command.tag, true, expect)?;
        expectation_met |= reply.expectation_met;
        match reply.answer {
            Answer::Continue => conn.write(literal.data)?,
            Answer::Tagged(Status::Ok) => {
                return Err(Exit::protocol(
                    "server completed a command before its literal was sent",
                ));
            }
            refused => {
                return Ok(Reply {
                    answer: refused,
                    expectation_met,
                });
            }
        }
    }
    conn.write(command.last_line)?;
    let reply = wait(conn, command.tag, false, expect)?;
    Ok(Reply {
        answer: reply.answer,
        expectation_met: expectation_met || reply.expectation_met,
    })
}

/// Reads server responses, copying them to the transcript, until the tagged
/// answer for `tag`, or a continuation request when `want_continue`
/// (continuation requests are not copied). Literals inside untagged
/// responses are copied as raw bytes, so message content can never be
/// mistaken for a tagged answer.
fn wait(
    conn: &mut Connection,
    tag: &[u8],
    want_continue: bool,
    expect: Option<&Expect<'_>>,
) -> Result<Reply, Exit> {
    let mut expectation_met = false;
    loop {
        let Some(line) = conn.read_line()? else {
            return Ok(Reply {
                answer: Answer::Closed,
                expectation_met,
            });
        };
        if is_continuation(&line) {
            if !want_continue {
                return Err(Exit::protocol("unexpected continuation request"));
            }
            return Ok(Reply {
                answer: Answer::Continue,
                expectation_met,
            });
        }
        conn.emit(&line)?;
        if is_untagged(&line) {
            expectation_met |= expect.is_some_and(|e| e.met_by(&line));
            pass_literals(conn, line)?;
            continue;
        }
        let status =
            tagged_status(&line, tag).ok_or_else(|| Exit::protocol("unexpected server line"))?;
        return Ok(Reply {
            answer: Answer::Tagged(status),
            expectation_met,
        });
    }
}

/// Copies the literals an untagged response announces, and the rest of the
/// response after each, to the transcript.
fn pass_literals(conn: &mut Connection, mut line: Vec<u8>) -> Result<(), Exit> {
    while let Some(literal) = literal_len(&line)? {
        conn.pass_bytes(literal)?;
        line = conn
            .read_line()?
            .ok_or_else(|| Exit::protocol("connection closed after a literal"))?;
        conn.emit(&line)?;
    }
    Ok(())
}

/// LOGOUT is best effort, and its failure is silent: the commands' outcome
/// is already known (after an APPEND, reporting a failure here could lead
/// to a duplicate draft).
fn logout(conn: &mut Connection) {
    if conn.write(&[LOGOUT_TAG, b" LOGOUT\r\n"].concat()).is_err() {
        return;
    }
    while let Ok(Some(line)) = conn.read_line() {
        if conn.emit(&line).is_err() || tagged_status(&line, LOGOUT_TAG).is_some() {
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::net::{TcpListener, TcpStream};

    /// Runs `login` against a server that reads the LOGIN line, then sends
    /// `answer` (if any) and closes the connection.
    fn login_against(answer: &'static [u8]) -> Result<(), Exit> {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        let server = std::thread::spawn(move || {
            let (peer, _) = listener.accept().expect("accept");
            let mut reader = BufReader::new(peer);
            let mut line = Vec::new();
            reader.read_until(b'\n', &mut line).expect("read LOGIN");
            reader.get_mut().write_all(answer).expect("answer");
        });
        let creds = Credentials {
            user: Zeroizing::new(b"user@example.com".to_vec()),
            pass: Zeroizing::new(b"fixture-password".to_vec()),
        };
        let mut conn = Connection::new(TcpStream::connect(addr).expect("connect"));
        let result = login(&mut conn, &creds);
        drop(conn);
        server.join().expect("server");
        result
    }

    #[test]
    fn a_rejected_login_is_an_authentication_failure() {
        assert_eq!(
            login_against(b"L NO [AUTHENTICATIONFAILED] invalid\r\n"),
            Err(Exit::auth("IMAP login rejected"))
        );
    }

    #[test]
    fn a_connection_closed_during_login_is_a_protocol_failure() {
        assert_eq!(
            login_against(b""),
            Err(Exit::protocol("server closed the connection during login"))
        );
    }
}
