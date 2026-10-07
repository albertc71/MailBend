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

/// A directive after a command: one of its untagged responses must meet it,
/// or the run stops as if the command had been rejected.
#[derive(Debug, PartialEq, Eq)]
pub enum Expect<'a> {
    /// `=EXPECT <text>`: a response starts with the text (any case).
    Prefix(&'a [u8]),
    /// `=EXPECT-WORD <word>`: a response holds the word (any case).
    Word(&'a [u8]),
}

impl Expect<'_> {
    pub fn text(&self) -> &[u8] {
        match self {
            Expect::Prefix(text) | Expect::Word(text) => text,
        }
    }

    /// Whether the server line `line` is an untagged response meeting this
    /// directive.
    pub fn met_by(&self, line: &[u8]) -> bool {
        is_untagged(line)
            && match self {
                Expect::Prefix(text) => starts_with_ignore_case(line, text),
                Expect::Word(word) => has_word(line, word),
            }
    }
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
    let directive = if rest.starts_with(EXPECT_WORD) {
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
    let expect = if directive == EXPECT_WORD {
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
