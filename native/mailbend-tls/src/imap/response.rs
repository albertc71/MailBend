//! Classifying the server's IMAP response lines.

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
}
