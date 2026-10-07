//! Parsing SMTP replies and the extensions an EHLO reply lists.

use crate::Exit;
use crate::text::{has_word, lines, starts_with_ignore_case};

/// One line of a (possibly multi-line) reply.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ReplyLine {
    pub code: u16,
    /// Whether more lines of the same reply follow (`250-...`).
    pub more: bool,
}

/// Parses `line`: three digits, then a separator.
pub fn parse_line(line: &[u8]) -> Result<ReplyLine, Exit> {
    match line {
        [a, b, c, separator, ..] if [a, b, c].iter().all(|d| d.is_ascii_digit()) => {
            let digit = |d: &u8| u16::from(d - b'0');
            Ok(ReplyLine {
                code: digit(a) * 100 + digit(b) * 10 + digit(c),
                more: *separator == b'-',
            })
        }
        _ => Err(Exit::protocol("malformed SMTP reply")),
    }
}

/// The text after a reply line's code and separator.
fn text(line: &[u8]) -> &[u8] {
    line.get(4..).unwrap_or_default()
}

/// Whether the EHLO reply lists the extension `keyword` ("250-KEYWORD ..."
/// or "250 KEYWORD", any case).
pub fn has_extension(ehlo: &[u8], keyword: &[u8]) -> bool {
    lines(ehlo).any(|line| {
        let text = text(line);
        starts_with_ignore_case(text, keyword)
            && matches!(text.get(keyword.len()), None | Some(b' ' | b'\r' | b'\n'))
    })
}

/// Whether the EHLO reply's AUTH line lists the mechanism `mechanism`.
pub fn has_auth(ehlo: &[u8], mechanism: &[u8]) -> bool {
    lines(ehlo).any(|line| {
        let text = text(line);
        // From the space after "AUTH", so the first mechanism is a word too.
        starts_with_ignore_case(text, b"AUTH ") && has_word(&text[4..], mechanism)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reply_lines_carry_a_code_and_a_continuation_mark() {
        assert_eq!(
            parse_line(b"250-PIPELINING\r\n"),
            Ok(ReplyLine {
                code: 250,
                more: true
            })
        );
        assert_eq!(
            parse_line(b"354 go\r\n"),
            Ok(ReplyLine {
                code: 354,
                more: false
            })
        );
        assert!(parse_line(b"25\r\n").is_err());
        assert!(parse_line(b"abc d\r\n").is_err());
    }

    #[test]
    fn extensions_and_mechanisms_are_whole_words() {
        let ehlo = b"250-smtp.test\r\n250-STARTTLS\r\n250-AUTH LOGIN plain\r\n250 SIZE\r\n";
        assert!(has_extension(ehlo, b"STARTTLS"));
        assert!(has_extension(ehlo, b"size"));
        assert!(!has_extension(ehlo, b"START"));
        assert!(has_auth(ehlo, b"PLAIN"));
        assert!(has_auth(ehlo, b"LOGIN"));
        assert!(!has_auth(ehlo, b"XOAUTH2"));
        assert!(!has_auth(b"250 AUTH PLAINX\r\n", b"PLAIN"));
        assert!(!has_auth(b"250 AUTHX PLAIN\r\n", b"PLAIN"));
    }
}
