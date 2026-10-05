//! IMAP: the Bend-generated command script and the server's responses.

pub mod response;
pub mod script;
pub(crate) mod session;

use crate::Exit;
use crate::limits::MAX_LITERAL;

/// The tags of the helper's own LOGIN and LOGOUT, refused in the script.
pub(crate) const LOGIN_TAG: &[u8] = b"L";
pub(crate) const LOGOUT_TAG: &[u8] = b"Z";

/// `Some(N)` if the line ends in `{N}\r\n` (a synchronizing literal follows),
/// for script and server lines alike. Non-synchronizing `{N+}` literals are
/// neither sent by MailBend nor accepted from servers.
pub fn literal_len(line: &[u8]) -> Result<Option<u64>, Exit> {
    let Some(head) = line.strip_suffix(b"}\r\n") else {
        return Ok(None);
    };
    let digits_start = head
        .iter()
        .rposition(|b| !b.is_ascii_digit())
        .map_or(0, |i| i + 1);
    let digits = &head[digits_start..];
    if digits.is_empty() || digits_start == 0 || head[digits_start - 1] != b'{' {
        return Ok(None);
    }
    let mut value: u64 = 0;
    for &d in digits {
        value = value * 10 + u64::from(d - b'0');
        if value > MAX_LITERAL {
            return Err(Exit::protocol("literal exceeds the literal limit"));
        }
    }
    Ok(Some(value))
}

/// Appends `s` to `out` as an IMAP quoted string.
pub(crate) fn push_quoted(out: &mut Vec<u8>, s: &[u8]) {
    out.push(b'"');
    for &c in s {
        if c == b'"' || c == b'\\' {
            out.push(b'\\');
        }
        out.push(c);
    }
    out.push(b'"');
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Failure;

    #[test]
    fn literals_end_lines() {
        assert_eq!(literal_len(b"a1 APPEND x {12}\r\n"), Ok(Some(12)));
        assert_eq!(literal_len(b"{0}\r\n"), Ok(Some(0)));
        for no_literal in [
            &b"0}\r\n"[..],
            b"a1 {}\r\n",
            b"a1 {12+}\r\n",
            b"a1 {12}\n",
            b"a1 12}\r\n",
        ] {
            assert_eq!(literal_len(no_literal), Ok(None));
        }
        assert_eq!(literal_len(b"* {67108864}\r\n"), Ok(Some(MAX_LITERAL)));
        assert_eq!(
            literal_len(b"* {67108865}\r\n").map_err(|e| e.failure),
            Err(Failure::Protocol)
        );
    }

    #[test]
    fn quoting_escapes_quotes_and_backslashes() {
        let mut out = Vec::new();
        push_quoted(&mut out, br#"a"b\c"#);
        assert_eq!(out, br#""a\"b\\c""#);
    }
}
