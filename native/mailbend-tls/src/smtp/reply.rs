//! Parsing SMTP replies and the extensions an EHLO reply lists.

use crate::Exit;
use crate::text::{lines, starts_with_ignore_case};

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

/// Exact tokens from AUTH lines. Keep the space after AUTH mandatory (no
/// legacy AUTH=), and use the report's ASCII-whitespace separation for both
/// observations and authentication. IMAP's closing `]` is not a separator.
fn auth_tokens(ehlo: &[u8]) -> impl Iterator<Item = &[u8]> {
    lines(ehlo)
        .map(text)
        .filter(|line| starts_with_ignore_case(line, b"AUTH "))
        .flat_map(|line| {
            line[5..]
                .split(u8::is_ascii_whitespace)
                .filter(|token| !token.is_empty())
        })
}

/// Whether the EHLO reply's AUTH line lists the exact mechanism `mechanism`.
pub fn has_auth(ehlo: &[u8], mechanism: &[u8]) -> bool {
    auth_tokens(ehlo).any(|token| token.eq_ignore_ascii_case(mechanism))
}

/// Fixed AUTH observations for a protected diagnostic EHLO reply.
pub fn auth_facts(ehlo: &[u8]) -> String {
    const ALLOWED: [&str; 4] = ["PLAIN", "LOGIN", "XOAUTH2", "OAUTHBEARER"];
    let mut offered = [false; ALLOWED.len()];
    let mut unknown = 0;
    for token in auth_tokens(ehlo) {
        if let Some(index) = ALLOWED
            .iter()
            .position(|known| token.eq_ignore_ascii_case(known.as_bytes()))
        {
            offered[index] = true;
        } else {
            unknown += 1;
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
    fn report_mechanisms_are_exact_tokens() {
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

    #[test]
    fn authentication_requires_exact_mechanism_tokens() {
        for token in [
            "PLAIN]",
            "[PLAIN",
            "PLAINX",
            "XPLAIN",
            "PLAIN=",
            "PLAIN,",
            "PLAIN.LOGIN",
            "PLAIN@example.com",
            "PLAIN\0",
            "PLAIN\u{a0}",
        ] {
            let ehlo = format!("250 AUTH {token} LOGIN\r\n");
            assert!(!has_auth(ehlo.as_bytes(), b"PLAIN"), "{token:?}");
            assert!(has_auth(ehlo.as_bytes(), b"LOGIN"), "{token:?}");
            assert_eq!(
                auth_facts(ehlo.as_bytes()),
                "smtp_auth LOGIN\nsmtp_auth_other 1\n"
            );
        }
        assert!(!has_auth(b"250 AUTH LOGIN]\r\n", b"LOGIN"));
        assert!(!has_auth(b"250 AUTH \r\n", b""));
    }

    #[test]
    fn authentication_preserves_case_spaces_lines_and_end_of_input() {
        for ehlo in [
            &b"250 AUTH PLAIN"[..],
            b"250-AuTh   pLaIn  LOGIN \r\n250 SIZE 1000\r\n",
            b"250-smtp.test\r\n250-AUTH LOGIN\r\n250 AUTH PLAIN\r\n",
            b"250 AUTH PLAIN PLAIN\r\n",
        ] {
            assert!(has_auth(ehlo, b"PLAIN"));
            assert!(has_auth(ehlo, b"plain"));
        }
    }

    #[test]
    fn authentication_and_reporting_use_the_same_token_spacing() {
        for separator in [b' ', b'\t', b'\r', 0x0c] {
            let mut ehlo = b"250 AUTH LOGIN".to_vec();
            ehlo.push(separator);
            ehlo.extend_from_slice(b"pLaIn\r\n");
            assert!(has_auth(&ehlo, b"PLAIN"), "{separator:?}");
            assert_eq!(
                auth_facts(&ehlo),
                "smtp_auth PLAIN\nsmtp_auth LOGIN\nsmtp_auth_other 0\n"
            );
        }
    }

    #[test]
    fn auth_keyword_still_requires_a_space_and_legacy_equals_is_ignored() {
        for ehlo in [
            &b"250 AUTH=PLAIN LOGIN\r\n"[..],
            b"250 AUTHX PLAIN LOGIN\r\n",
            b"250 AUTH\tPLAIN LOGIN\r\n",
            b"250 XAUTH PLAIN LOGIN\r\n",
            b"250 SIZE PLAIN LOGIN\r\n",
            b"250 AUTH\r\n",
        ] {
            assert!(!has_auth(ehlo, b"PLAIN"));
            assert!(!has_auth(ehlo, b"LOGIN"));
            assert_eq!(auth_facts(ehlo), "smtp_auth_other 0\n");
        }
    }
}
