//! Classifying the server's IMAP response lines.

use crate::exit::AuthReason;
use crate::text::starts_with_ignore_case;

/// The status of a tagged response.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    Ok,
    No,
    Bad,
}

/// What the server's first line allows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Greeting {
    /// `* OK`: the helper logs in.
    Ok,
    /// `* PREAUTH`: already authenticated.
    Preauth,
}

/// The greeting in `line`, or `None` if the server refused the connection
/// (`* BYE`) or sent something else.
pub fn greeting(line: &[u8]) -> Option<Greeting> {
    if starts_with_ignore_case(line, b"* PREAUTH") {
        Some(Greeting::Preauth)
    } else if starts_with_ignore_case(line, b"* OK") {
        Some(Greeting::Ok)
    } else {
        None
    }
}

pub(crate) fn is_untagged(line: &[u8]) -> bool {
    line.first() == Some(&b'*')
}

/// A whole BYE status, not a prefix such as BYEOTHER or text in a literal.
pub(crate) fn is_bye(line: &[u8]) -> bool {
    starts_with_ignore_case(line, b"* BYE") && matches!(line.get(5), Some(b' ' | b'\r'))
}

/// Reads only the bracketed response code immediately after a status.
/// Callers first establish the tag/status or BYE framing. Free text is never
/// searched, retained in the result, or interpreted as a response code.
pub(crate) fn refusal_reason(line: &[u8], fallback: AuthReason) -> AuthReason {
    let line = line.strip_suffix(b"\r\n").unwrap_or(line);
    let mut words = line.splitn(3, |byte| *byte == b' ');
    let tag = words.next().unwrap_or_default();
    let status = words.next().unwrap_or_default();
    let framed = if tag == b"*" {
        status.eq_ignore_ascii_case(b"BYE")
    } else {
        status.eq_ignore_ascii_case(b"NO") || status.eq_ignore_ascii_case(b"BAD")
    };
    if !framed {
        return AuthReason::Unknown;
    }
    let Some(text) = words.next() else {
        return fallback;
    };
    let Some(code) = text.strip_prefix(b"[") else {
        return fallback;
    };
    let Some(end) = code.iter().position(|byte| *byte == b']') else {
        return AuthReason::Unknown;
    };
    if !matches!(code.get(end + 1), None | Some(b' ')) {
        return AuthReason::Unknown;
    }
    let code = &code[..end];
    for (name, reason) in [
        (b"AUTHENTICATIONFAILED".as_slice(), AuthReason::Credentials),
        (b"UNAVAILABLE", AuthReason::Temporary),
        (b"LIMIT", AuthReason::Limit),
        (b"INUSE", AuthReason::InUse),
        (b"EXPIRED", AuthReason::Expired),
        (b"CONTACTADMIN", AuthReason::ContactAdmin),
    ] {
        if code.eq_ignore_ascii_case(name) {
            return reason;
        }
    }
    AuthReason::Unknown
}

/// A `+` continuation request.
pub fn is_continuation(line: &[u8]) -> bool {
    line.first() == Some(&b'+') && matches!(line.get(1), None | Some(b' ' | b'\r'))
}

/// The status of `line` if it is the tagged response for `tag`.
pub fn tagged_status(line: &[u8], tag: &[u8]) -> Option<Status> {
    let rest = line.strip_prefix(tag)?.strip_prefix(b" ")?;
    Some(status_word(rest))
}

/// OK or NO (any case) followed by a space or CR; anything else, including
/// BAD, counts as BAD.
fn status_word(rest: &[u8]) -> Status {
    let word = |w: &[u8]| {
        starts_with_ignore_case(rest, w) && matches!(rest.get(w.len()), Some(b' ' | b'\r'))
    };
    if word(b"OK") {
        Status::Ok
    } else if word(b"NO") {
        Status::No
    } else {
        Status::Bad
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tagged_statuses_need_the_tag_and_a_whole_word() {
        assert_eq!(tagged_status(b"a1 OK done\r\n", b"a1"), Some(Status::Ok));
        assert_eq!(tagged_status(b"a1 ok\r\n", b"a1"), Some(Status::Ok));
        assert_eq!(
            tagged_status(b"a1 NO [TRYCREATE] x\r\n", b"a1"),
            Some(Status::No)
        );
        assert_eq!(tagged_status(b"a1 OKAY\r\n", b"a1"), Some(Status::Bad));
        assert_eq!(tagged_status(b"a1 BAD x\r\n", b"a1"), Some(Status::Bad));
        assert_eq!(tagged_status(b"a12 OK\r\n", b"a1"), None);
        assert_eq!(tagged_status(b"* OK\r\n", b"a1"), None);
    }

    #[test]
    fn greetings_and_continuations() {
        assert_eq!(greeting(b"* OK ready\r\n"), Some(Greeting::Ok));
        assert_eq!(greeting(b"* preauth hi\r\n"), Some(Greeting::Preauth));
        assert_eq!(greeting(b"* BYE busy\r\n"), None);
        assert!(is_continuation(b"+ go\r\n"));
        assert!(is_continuation(b"+\r\n"));
        assert!(!is_continuation(b"+x\r\n"));
        assert!(is_untagged(b"* 1 EXISTS\r\n"));
    }

    #[test]
    fn refusal_codes_are_bounded_words_at_the_status_position() {
        for (code, expected) in [
            ("AUTHENTICATIONFAILED", AuthReason::Credentials),
            ("unavailable", AuthReason::Temporary),
            ("LIMIT", AuthReason::Limit),
            ("INUSE", AuthReason::InUse),
            ("EXPIRED", AuthReason::Expired),
            ("CONTACTADMIN", AuthReason::ContactAdmin),
        ] {
            let line = format!("L NO [{code}] private server text\r\n");
            assert_eq!(
                refusal_reason(line.as_bytes(), AuthReason::Credentials),
                expected
            );
        }
        for line in [
            b"L NO [UNAVAILABLEX] private\r\n".as_slice(),
            b"L NO [XUNAVAILABLE] private\r\n",
            b"L NO [UNAVAILABLE extra] private\r\n",
            b"L NO [UNAVAILABLE]suffix private\r\n",
            b"L NO [UNAVAILABLE private\r\n",
            b"L NO [private] [UNAVAILABLE]\r\n",
            b"L NOPE [AUTHENTICATIONFAILED] private\r\n",
            b"L WHATEVER [UNAVAILABLE] private\r\n",
            b"L OK [AUTHENTICATIONFAILED] private\r\n",
            b"L BYE [UNAVAILABLE] private\r\n",
            b"* NO [AUTHENTICATIONFAILED] private\r\n",
        ] {
            assert_eq!(
                refusal_reason(line, AuthReason::Credentials),
                AuthReason::Unknown
            );
        }
        for line in [b"L NO private [UNAVAILABLE]\r\n".as_slice(), b"L NO\r\n"] {
            assert_eq!(
                refusal_reason(line, AuthReason::Credentials),
                AuthReason::Credentials
            );
        }
        assert!(is_bye(b"* bye [UNAVAILABLE] private\r\n"));
        assert!(!is_bye(b"* BYEOTHER private\r\n"));
        assert!(!is_bye(b"a1 NO * BYE private\r\n"));
    }
}
