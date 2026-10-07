//! The SMTP envelope on stdin: MAIL FROM, RCPT TO, ..., DATA and the
//! dot-stuffed message ending in a "." line. The helper does the greeting,
//! STARTTLS, authentication and QUIT itself, so the envelope may not. The
//! whole envelope is parsed before connecting.

use crate::Exit;
use crate::text::{crlf_line_at, is_verb};

/// Verbs the helper sends itself, refused in the envelope.
const HELPER_VERBS: [&[u8]; 5] = [b"AUTH", b"STARTTLS", b"EHLO", b"HELO", b"QUIT"];
/// The line that ends the message after DATA.
const END_OF_DATA: &[u8] = b".\r\n";

/// One exchange with the server.
#[derive(Debug, PartialEq, Eq)]
pub enum Step<'a> {
    /// A command line, answered by one reply.
    Command(&'a [u8]),
    /// The DATA line and, once the server asks for it, the message through
    /// its "." line.
    Data {
        command: &'a [u8],
        message: &'a [u8],
    },
}

/// Parses the whole envelope: CRLF lines, none of the helper's own verbs,
/// and a message that ends in a "." line after DATA.
pub fn parse(envelope: &[u8]) -> Result<Vec<Step<'_>>, Exit> {
    let mut steps = Vec::new();
    let mut p = 0;
    while p < envelope.len() {
        let line = &envelope[p..p + crlf_line_at(envelope, p, "envelope")?];
        p += line.len();
        if HELPER_VERBS.iter().any(|v| is_verb(line, v)) {
            return Err(Exit::usage(
                "the envelope may not greet, authenticate or quit",
            ));
        }
        if !is_verb(line, b"DATA") {
            steps.push(Step::Command(line));
            continue;
        }
        let message_start = p;
        loop {
            if p == envelope.len() {
                return Err(Exit::usage("message does not end in a \".\" line"));
            }
            let message_line = &envelope[p..p + crlf_line_at(envelope, p, "envelope")?];
            p += message_line.len();
            if message_line == END_OF_DATA {
                break;
            }
        }
        steps.push(Step::Data {
            command: line,
            message: &envelope[message_start..p],
        });
    }
    Ok(steps)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Failure;

    #[test]
    fn data_carries_its_message_where_helper_verbs_are_allowed() {
        assert_eq!(
            parse(b"MAIL FROM:<a@b>\r\nDATA\r\nQUIT\r\n.\r\nRSET\r\n"),
            Ok(vec![
                Step::Command(b"MAIL FROM:<a@b>\r\n"),
                Step::Data {
                    command: b"DATA\r\n",
                    message: b"QUIT\r\n.\r\n"
                },
                Step::Command(b"RSET\r\n"),
            ])
        );
        assert_eq!(parse(b""), Ok(vec![]));
    }

    #[test]
    fn invalid_envelopes_are_usage_errors() {
        for bad in [
            &b"EHLO x\r\n"[..],
            b"auth plain x\r\n",
            b"QUIT\r\n",
            b"DATA\r\nbody\r\n",
            b"DATA\r\n",
            b"MAIL FROM:<a@b>\n",
            b"MAIL FROM:<a@b>",
        ] {
            assert_eq!(parse(bad).map_err(|e| e.failure), Err(Failure::Usage));
        }
    }
}
