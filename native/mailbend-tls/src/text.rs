//! Byte-string helpers shared by the IMAP and SMTP parsers. Protocol text
//! is ASCII, so case is ignored the ASCII way.

use crate::Exit;

/// The length of the line starting at `p`, including its LF, if it has one.
pub fn line_at(buf: &[u8], p: usize) -> Option<usize> {
    buf.get(p..)?
        .iter()
        .position(|&b| b == b'\n')
        .map(|i| i + 1)
}

/// The length of the CRLF line starting at `p`; `what` names the input in
/// the usage error for a missing or bare LF.
pub fn crlf_line_at(buf: &[u8], p: usize, what: &str) -> Result<usize, Exit> {
    let len = line_at(buf, p).ok_or_else(|| Exit::usage(format!("{what} does not end in CRLF")))?;
    if len < 2 || buf[p + len - 2] != b'\r' {
        return Err(Exit::usage(format!("{what} lines must end in CRLF")));
    }
    Ok(len)
}

/// The lines of `buf`, each with its LF.
pub fn lines(buf: &[u8]) -> impl Iterator<Item = &[u8]> {
    buf.split_inclusive(|&b| b == b'\n')
}

pub fn starts_with_ignore_case(line: &[u8], prefix: &[u8]) -> bool {
    line.get(..prefix.len())
        .is_some_and(|head| head.eq_ignore_ascii_case(prefix))
}

/// Whether `line` starts with `verb` (any case) as a whole word.
pub fn is_verb(line: &[u8], verb: &[u8]) -> bool {
    starts_with_ignore_case(line, verb) && matches!(line.get(verb.len()), None | Some(b' ' | b'\r'))
}

/// Whether `line` holds `word` (any case) as a whole word: after a space,
/// and before a space, `]`, CR, LF or the end.
pub fn has_word(line: &[u8], word: &[u8]) -> bool {
    let wl = word.len();
    if wl == 0 || line.len() < wl + 1 {
        return false;
    }
    (1..=line.len() - wl).any(|i| {
        let after = line.get(i + wl).copied().unwrap_or(b' ');
        line[i - 1] == b' '
            && line[i..i + wl].eq_ignore_ascii_case(word)
            && matches!(after, b' ' | b'\r' | b'\n' | b']')
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Failure;

    #[test]
    fn crlf_lines_are_required() {
        assert_eq!(crlf_line_at(b"a\r\nb\r\n", 3, "input"), Ok(3));
        let err = |buf: &[u8]| crlf_line_at(buf, 0, "input").map_err(|e| (e.failure, e.message));
        assert_eq!(
            err(b"a\n"),
            Err((Failure::Usage, "input lines must end in CRLF".to_string()))
        );
        assert_eq!(
            err(b"a\r"),
            Err((Failure::Usage, "input does not end in CRLF".to_string()))
        );
    }

    #[test]
    fn verbs_are_whole_first_words() {
        assert!(is_verb(b"login x", b"LOGIN"));
        assert!(is_verb(b"LOGOUT\r\n", b"LOGOUT"));
        assert!(!is_verb(b"LOGINX", b"LOGIN"));
    }

    #[test]
    fn words_need_a_space_before_them() {
        assert!(has_word(b"* CAPABILITY IMAP4rev1 uidplus\r\n", b"UIDPLUS"));
        assert!(has_word(
            b"* OK [CAPABILITY IMAP4rev1 UIDPLUS]\r\n",
            b"UIDPLUS"
        ));
        assert!(!has_word(b"* OK [UIDPLUS]\r\n", b"UIDPLUS"));
        assert!(!has_word(b"* CAPABILITY XUIDPLUS\r\n", b"UIDPLUS"));
        assert!(!has_word(b"UIDPLUS\r\n", b"UIDPLUS"));
    }
}
