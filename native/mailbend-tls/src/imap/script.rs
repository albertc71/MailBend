//! The IMAP command script on stdin: tagged commands in wire form, each
//! optionally followed by an `=EXPECT` directive that is checked, not sent.
//! The whole script is parsed before connecting, so a malformed later
//! command is never found only after earlier ones have run.

use crate::Exit;
use crate::imap::response::is_untagged;
use crate::imap::{LOGIN_TAG, LOGOUT_TAG, literal_len};
use crate::text::{crlf_line_at, has_word, is_verb, starts_with_ignore_case};

/// Names the script in usage errors.
const SCRIPT: &str = "command script";
/// Verbs the helper performs itself, refused in the script.
const HELPER_VERBS: [&[u8]; 4] = [b"LOGIN", b"AUTHENTICATE", b"STARTTLS", b"LOGOUT"];
const EXPECT: &[u8] = b"=EXPECT ";
const EXPECT_WORD: &[u8] = b"=EXPECT-WORD ";
const EXPECT_CAPABILITIES: &[u8] = b"=EXPECT-CAPABILITIES ";
const CAPABILITIES: [&[u8]; 3] = [b"LIST-STATUS", b"CONDSTORE", b"SPECIAL-USE"];

/// A directive after a command: one of its untagged responses must meet it,
/// or the run stops as if the command had been rejected.
#[derive(Debug, PartialEq, Eq)]
pub enum Expect<'a> {
    /// `=EXPECT <text>`: a response starts with the text (any case).
    Prefix(&'a [u8]),
    /// `=EXPECT-WORD <word>`: a response holds the word (any case).
    Word(&'a [u8]),
    Capabilities(&'a [u8]),
}

impl Expect<'_> {
    pub fn text(&self) -> &[u8] {
        match self {
            Expect::Prefix(text) | Expect::Word(text) | Expect::Capabilities(text) => text,
        }
    }

    /// Whether the server line `line` is an untagged response meeting this
    /// directive.
    pub fn met_by(&self, line: &[u8]) -> bool {
        is_untagged(line)
            && match self {
                Expect::Prefix(text) => starts_with_ignore_case(line, text),
                Expect::Word(word) => has_word(line, word),
                Expect::Capabilities(required) => capability_matches(line, required),
            }
    }
}

pub fn is_capability_response(line: &[u8]) -> bool {
    line.strip_prefix(b"*")
        .and_then(|body| {
            body.split(u8::is_ascii_whitespace)
                .find(|word| !word.is_empty())
        })
        .is_some_and(|word| word.eq_ignore_ascii_case(b"CAPABILITY"))
}

fn capability_matches(line: &[u8], required: &[u8]) -> bool {
    let Some(body) = line.strip_suffix(b"\r\n") else {
        return false;
    };
    if !body
        .get(..13)
        .is_some_and(|prefix| prefix.eq_ignore_ascii_case(b"* CAPABILITY "))
    {
        return false;
    }
    body[13..].split(|&b| b == b' ').all(|token| {
        !token.is_empty()
            && token
                .iter()
                .all(|b| (0x21..=0x7e).contains(b) && !b"(){}%*\"\\[]".contains(b))
    }) && required.split(|&b| b == b' ').all(|want| {
        body[13..]
            .split(|&b| b == b' ')
            .any(|token| token.eq_ignore_ascii_case(want))
    })
}

/// A command line ending in `{N}`, and the N bytes the server must ask for
/// before they are sent.
#[derive(Debug, PartialEq, Eq)]
pub struct Literal<'a> {
    pub line: &'a [u8],
    pub data: &'a [u8],
}

/// One command of the script, split where it waits for the server.
#[derive(Debug, PartialEq, Eq)]
pub struct Command<'a> {
    pub tag: &'a [u8],
    /// The lines that announce a literal, each with its literal.
    pub literals: Vec<Literal<'a>>,
    /// The line that completes the command.
    pub last_line: &'a [u8],
    pub expect: Option<Expect<'a>>,
}

/// Parses the whole script.
pub fn parse(script: &[u8]) -> Result<Vec<Command<'_>>, Exit> {
    let mut commands = Vec::new();
    let mut p = 0;
    while p < script.len() {
        let (command, next) = parse_command(script, p)?;
        commands.push(command);
        p = next;
    }
    Ok(commands)
}

/// The command starting at `p`, and where the next one starts.
fn parse_command(script: &[u8], mut p: usize) -> Result<(Command<'_>, usize), Exit> {
    let tag = parse_tag(&script[p..p + crlf_line_at(script, p, SCRIPT)?])?;
    let mut literals = Vec::new();
    loop {
        let line = &script[p..p + crlf_line_at(script, p, SCRIPT)?];
        p += line.len();
        let Some(len) = literal_len(line)? else {
            let (expect, next) = parse_expect(script, p)?;
            if matches!(expect, Some(Expect::Capabilities(_)))
                && (!literals.is_empty()
                    || !line[tag.len() + 1..].eq_ignore_ascii_case(b"CAPABILITY\r\n"))
            {
                return Err(Exit::usage("=EXPECT-CAPABILITIES must follow CAPABILITY"));
            }
            let command = Command {
                tag,
                literals,
                last_line: line,
                expect,
            };
            return Ok((command, next));
        };
        let data = usize::try_from(len)
            .ok()
            .and_then(|len| script.get(p..p + len))
            .ok_or_else(|| Exit::usage("literal runs past the end of the script"))?;
        p += data.len();
        literals.push(Literal { line, data });
    }
}

/// The tag of a command's first line. It may not be one of the helper's
/// own, nor may the command be one the helper performs itself.
fn parse_tag(first_line: &[u8]) -> Result<&[u8], Exit> {
    let space = first_line
        .iter()
        .position(|&b| b == b' ')
        .ok_or_else(|| Exit::usage("command without a tag"))?;
    let (tag, verb) = (&first_line[..space], &first_line[space + 1..]);
    let valid = (1..=16).contains(&tag.len())
        && tag.iter().all(u8::is_ascii_alphanumeric)
        && tag != LOGIN_TAG
        && tag != LOGOUT_TAG;
    if !valid {
        return Err(Exit::usage("invalid or reserved command tag"));
    }
    if HELPER_VERBS.iter().any(|v| is_verb(verb, v)) {
        return Err(Exit::usage("the script may not authenticate or log out"));
    }
    Ok(tag)
}

/// The directive at `p`, if there is one, and where the next command
/// starts.
fn parse_expect(script: &[u8], p: usize) -> Result<(Option<Expect<'_>>, usize), Exit> {
    let rest = &script[p..];
    let directive = if rest.starts_with(EXPECT_CAPABILITIES) {
        EXPECT_CAPABILITIES
    } else if rest.starts_with(EXPECT_WORD) {
        EXPECT_WORD
    } else if rest.starts_with(EXPECT) {
        EXPECT
    } else {
        return Ok((None, p));
    };
    let len = crlf_line_at(script, p, SCRIPT)?;
    let text = &script[p + directive.len()..p + len - 2];
    if text.is_empty() {
        return Err(Exit::usage("an =EXPECT line needs text and CRLF"));
    }
    if !text.iter().all(|b| (0x20..=0x7E).contains(b)) {
        return Err(Exit::usage("=EXPECT text must be printable ASCII"));
    }
    let expect = if directive == EXPECT_CAPABILITIES {
        if text.len() > 33 {
            return Err(Exit::usage(
                "=EXPECT-CAPABILITIES needs distinct supported capabilities",
            ));
        }
        let mut seen = 0u8;
        for token in text.split(|&b| b == b' ') {
            let Some(index) = CAPABILITIES
                .iter()
                .position(|known| token.eq_ignore_ascii_case(known))
            else {
                return Err(Exit::usage(
                    "=EXPECT-CAPABILITIES needs distinct supported capabilities",
                ));
            };
            let bit = 1 << index;
            if seen & bit != 0 {
                return Err(Exit::usage(
                    "=EXPECT-CAPABILITIES needs distinct supported capabilities",
                ));
            }
            seen |= bit;
        }
        Expect::Capabilities(text)
    } else if directive == EXPECT_WORD {
        if text.contains(&b' ') {
            return Err(Exit::usage("=EXPECT-WORD takes one word"));
        }
        Expect::Word(text)
    } else {
        Expect::Prefix(text)
    };
    Ok((Some(expect), p + len))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Failure;

    #[test]
    fn capabilities_are_a_finite_conjunction_after_capability_only() {
        let commands = parse(b"a1 CAPABILITY\r\n=EXPECT-CAPABILITIES LIST-STATUS CONDSTORE\r\n")
            .expect("valid capability gate");
        let expect = commands[0].expect.as_ref().expect("gate");
        assert!(expect.met_by(b"* CAPABILITY IMAP4rev1 condstore list-status\r\n"));
        for line in [
            b"* CAPABILITY IMAP4rev1 LIST-STATUS\r\n".as_slice(),
            b"* CAPABILITY IMAP4rev1 XLIST-STATUS CONDSTORE\r\n",
            b"* OK [ALERT] LIST-STATUS CONDSTORE\r\n",
            b"* CAPABILITY \"LIST-STATUS\" CONDSTORE\r\n",
            b"* CAPABILITY LIST-STATUS CONDSTORE {3}\r\n",
            b"* CAPABILITY LIST-STATUS CONDSTORE\r\nextra",
            b"* CAPABILITY LIST-STATUS  CONDSTORE\r\n",
            b"*CAPABILITY LIST-STATUS CONDSTORE\r\n",
            b"*\tCAPABILITY LIST-STATUS CONDSTORE\r\n",
        ] {
            assert!(!expect.met_by(line), "{line:?}");
        }
        for script in [
            b"a1 NOOP\r\n=EXPECT-CAPABILITIES LIST-STATUS\r\n".as_slice(),
            b"a1 CAPABILITY extra\r\n=EXPECT-CAPABILITIES LIST-STATUS\r\n",
            b"a1 CAPABILITY\r\n=EXPECT-CAPABILITIES UIDPLUS\r\n",
            b"a1 CAPABILITY\r\n=EXPECT-CAPABILITIES LIST-STATUS LIST-STATUS\r\n",
            b"a1 CAPABILITY\r\n=EXPECT-CAPABILITIES \r\n",
            b"a1 CAPABILITY\r\n=EXPECT-CAPABILITIES LIST-STATUS  CONDSTORE\r\n",
            b"a1 CAPABILITY\r\n=EXPECT-CAPABILITIES LIST-STATUS CONDSTORE SPECIAL-USE X\r\n",
        ] {
            assert!(parse(script).is_err(), "{script:?}");
        }
        assert!(
            parse(b"a1 CAPABILITY\r\n=EXPECT-CAPABILITIES LIST-STATUS CONDSTORE SPECIAL-USE\r\n")
                .is_ok()
        );
        assert!(is_capability_response(b"*CAPABILITY CONDSTORE\r\n"));
        assert!(is_capability_response(b"*\tCAPABILITY CONDSTORE\r\n"));
    }

    #[test]
    fn commands_split_at_literals_and_carry_their_directives() {
        let script = b"a1 SELECT INBOX\r\n=EXPECT * OK [UIDVALIDITY 1]\r\n\
                       a2 APPEND D {3}\r\nabc FLAGS {1}\r\nx\r\n\
                       a3 NOOP\r\n=EXPECT-WORD UIDPLUS\r\n";
        let commands = parse(script).expect("valid");
        assert_eq!(
            commands,
            [
                Command {
                    tag: b"a1",
                    literals: vec![],
                    last_line: b"a1 SELECT INBOX\r\n",
                    expect: Some(Expect::Prefix(b"* OK [UIDVALIDITY 1]")),
                },
                Command {
                    tag: b"a2",
                    literals: vec![
                        Literal {
                            line: b"a2 APPEND D {3}\r\n",
                            data: b"abc"
                        },
                        Literal {
                            line: b" FLAGS {1}\r\n",
                            data: b"x"
                        },
                    ],
                    last_line: b"\r\n",
                    expect: None,
                },
                Command {
                    tag: b"a3",
                    literals: vec![],
                    last_line: b"a3 NOOP\r\n",
                    expect: Some(Expect::Word(b"UIDPLUS")),
                },
            ]
        );
    }

    #[test]
    fn directives_match_untagged_responses_only() {
        let prefix = Expect::Prefix(b"* OK [UIDVALIDITY 7]");
        assert!(prefix.met_by(b"* ok [uidvalidity 7]\r\n"));
        assert!(!prefix.met_by(b"* OK [UIDVALIDITY 8]\r\n"));
        assert!(!prefix.met_by(b"a1 OK [UIDVALIDITY 7]\r\n"));
        let word = Expect::Word(b"UIDPLUS");
        assert!(word.met_by(b"* CAPABILITY IMAP4rev1 uidplus\r\n"));
        assert!(!word.met_by(b"a1 OK UIDPLUS\r\n"));
    }

    #[test]
    fn invalid_scripts_are_usage_errors() {
        let cases: [(&[u8], &str); 14] = [
            (b"L NOOP\r\n", "reserved"),
            (b"Z NOOP\r\n", "reserved"),
            (b"a-1 NOOP\r\n", "reserved"),
            (b"a1234567890123456 NOOP\r\n", "reserved"),
            (b"a1 LOGIN x y\r\n", "authenticate"),
            (b"a1 logout\r\n", "authenticate"),
            (b"NOOP\r\n", "tag"),
            (b"a1 NOOP\n", "CRLF"),
            (b"a1 NOOP\r\na2 NOOP", "CRLF"),
            (b"a1 APPEND x {9}\r\nabc\r\n", "past the end"),
            (b"a1 NOOP\r\n=EXPECT \r\n", "needs text"),
            (b"a1 NOOP\r\n=EXPECT-WORD A B\r\n", "one word"),
            (b"a1 NOOP\r\n=EXPECT \xe9\r\n", "printable"),
            (b"a1 NOOP\r\n=EXPECT x\n", "CRLF"),
        ];
        for (script, reason) in cases {
            let err = parse(script).expect_err(reason);
            assert_eq!(err.failure, Failure::Usage, "{reason}");
            assert!(err.message.contains(reason), "{reason}: {}", err.message);
        }
        assert!(parse(b"LL NOOP\r\n").is_ok());
        assert_eq!(parse(b""), Ok(vec![]));
    }
}
