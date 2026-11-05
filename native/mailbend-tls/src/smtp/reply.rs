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
        [a, b, c, separator, ..]
            if [a, b, c].iter().all(|d| d.is_ascii_digit())
                && (matches!(separator, b' ' | b'-') || line.get(3..) == Some(b"\r\n")) =>
        {
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

/// Fixed AUTH observations for a protected diagnostic EHLO reply.
pub fn auth_facts(ehlo: &[u8]) -> String {
    const ALLOWED: [&str; 4] = ["PLAIN", "LOGIN", "XOAUTH2", "OAUTHBEARER"];
    let mut offered = [false; ALLOWED.len()];
    let mut unknown = 0;
    for line in lines(ehlo).map(text) {
        if !starts_with_ignore_case(line, b"AUTH ") {
            continue;
        }
        for token in line[5..]
            .split(u8::is_ascii_whitespace)
            .filter(|t| !t.is_empty())
        {
            if let Some(index) = ALLOWED
                .iter()
                .position(|known| token.eq_ignore_ascii_case(known.as_bytes()))
            {
                offered[index] = true;
            } else {
                unknown += 1;
            }
        }
    }
    let mut facts = String::new();
    for (mechanism, present) in ALLOWED.into_iter().zip(offered) {
        if present {
            facts.push_str("smtp_auth ");
            facts.push_str(mechanism);
            facts.push('\n');
        }
    }
    facts.push_str(&format!("smtp_auth_other {unknown}\n"));
    facts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auth_report_redacts_unknown_mechanisms_and_deduplicates_known_ones() {
        assert_eq!(
            auth_facts(b"250-private.example\r\n250-AUTH plain LOGIN XOAUTH2 OAUTHBEARER private@example.com PLAIN\r\n250 AUTH strange-secret\r\n"),
            "smtp_auth PLAIN\nsmtp_auth LOGIN\nsmtp_auth XOAUTH2\nsmtp_auth OAUTHBEARER\nsmtp_auth_other 2\n"
        );
        assert_eq!(auth_facts(b"250 AUTHX PLAIN\r\n"), "smtp_auth_other 0\n");
    }

    #[test]
    fn report_mechanisms_are_exact_tokens_not_authentication_word_prefixes() {
        assert_eq!(
            auth_facts(b"250 AUTH PLAIN] LOGIN@example.com XOAUTH2x\r\n"),
            "smtp_auth_other 3\n"
        );
    }

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
        assert!(parse_line(b"250xnot a reply\r\n").is_err());
        assert_eq!(
            parse_line(b"250\r\n"),
            Ok(ReplyLine {
                code: 250,
                more: false
            })
        );
        assert!(parse_line(b"250\rx").is_err());
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
