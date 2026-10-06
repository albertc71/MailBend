//! The pure parts of `mailbend-attach`: argument checks, path relativisation,
//! send counting and error messages. Everything that touches the file system
//! is in `main.rs`.

use std::fmt;

use nix::errno::Errno;

/// No attachment is ever larger than 25 MiB, whatever the caller asks for.
pub const MAX_ATTACHMENT: u64 = 25 << 20;

/// Directories whose presence marks a directory as not a dedicated
/// attachment directory: every file inside it could be mailed.
pub const SENSITIVE: [&str; 5] = [".ssh", ".gnupg", ".aws", ".config", ".git"];

/// A positive decimal number, digits only.
fn parse_positive(arg: &[u8]) -> Option<u64> {
    let digits = std::str::from_utf8(arg).ok()?;
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    digits.parse::<u64>().ok().filter(|&v| v > 0)
}

/// The byte limit argument: a positive decimal number, capped at
/// `MAX_ATTACHMENT`.
pub fn parse_max(arg: &[u8]) -> Result<u64, String> {
    parse_positive(arg)
        .map(|v| v.min(MAX_ATTACHMENT))
        .ok_or_else(|| format!("bad byte limit {}", show(arg)))
}

/// The daily send limit argument: a positive decimal number.
pub fn parse_limit(arg: &[u8]) -> Result<u64, String> {
    parse_positive(arg).ok_or_else(|| format!("bad send limit {}", show(arg)))
}

/// The UTC day argument, `YYYY-MM-DD`, which is also the counter's line for
/// one send that day.
pub fn parse_day(arg: &[u8]) -> Result<&[u8], String> {
    let shaped = arg.len() == 10
        && arg.iter().enumerate().all(|(i, &b)| match i {
            4 | 7 => b == b'-',
            _ => b.is_ascii_digit(),
        });
    if shaped {
        Ok(arg)
    } else {
        Err(format!("bad day {}", show(arg)))
    }
}

/// How many sends the counter's contents (one day per line) hold for `day`.
pub fn sends_on(counter: &[u8], day: &[u8]) -> u64 {
    let lines = counter.split(|&b| b == b'\n');
    lines.filter(|&line| line == day).count() as u64
}

/// The answer to a reservation, printed as `ok <n>` or `full <n>`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reservation {
    /// One more send was counted; `n` counts it too.
    Reserved(u64),
    /// The limit was already reached with `n` sends; nothing was counted.
    Full(u64),
}

impl Reservation {
    /// The reservation when `counted` sends are already counted today.
    pub fn new(counted: u64, limit: u64) -> Self {
        if counted < limit {
            Self::Reserved(counted + 1)
        } else {
            Self::Full(counted)
        }
    }
}

impl fmt::Display for Reservation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Reserved(n) => write!(f, "ok {n}"),
            Self::Full(n) => write!(f, "full {n}"),
        }
    }
}

/// `path` relative to the attachment directory. A relative `path` is used as
/// given; an absolute one must lie inside `root` (the canonical directory)
/// or inside `dir` as the caller spelled it.
pub fn relative_attachment_path<'a>(
    dir: &[u8],
    root: &[u8],
    path: &'a [u8],
) -> Result<&'a [u8], String> {
    let mut relative = path;
    if path.first() == Some(&b'/') {
        let mut dir_length = dir.len();
        while dir_length > 1 && dir[dir_length - 1] == b'/' {
            dir_length -= 1;
        }
        let dir = &dir[..dir_length];
        relative = if let Some(rest) = strip_directory(path, root) {
            rest
        } else if let Some(rest) = strip_directory(path, dir) {
            rest
        } else {
            return Err(format!(
                "attachment {} is outside MAILBEND_ATTACH_DIR",
                show(path)
            ));
        };
    }
    if relative.is_empty() {
        return Err("attachment path names no file".to_string());
    }
    Ok(relative)
}

/// The part of `path` after `directory` and one slash, if `path` lies in it.
fn strip_directory<'a>(path: &'a [u8], directory: &[u8]) -> Option<&'a [u8]> {
    path.strip_prefix(directory)?.strip_prefix(b"/")
}

/// Whether `outer` is `inner` or one of its parent directories (both
/// canonical).
pub fn contains_path(outer: &[u8], inner: &[u8]) -> bool {
    if outer == b"/" {
        return true;
    }
    match inner.strip_prefix(outer) {
        Some(rest) => rest.is_empty() || rest.first() == Some(&b'/'),
        None => false,
    }
}

/// The reason opening the attachment directory failed.
pub fn directory_open_error(errno: Errno) -> String {
    match errno {
        Errno::ENOSYS => "attachments need Linux 5.6+ (openat2)".to_string(),
        Errno::ELOOP => "MAILBEND_ATTACH_DIR changed while it was opened".to_string(),
        _ => "cannot open MAILBEND_ATTACH_DIR".to_string(),
    }
}

/// The reason opening the attachment beneath the directory failed.
pub fn attachment_open_error(errno: Errno, path: &[u8]) -> String {
    let path = show(path);
    match errno {
        Errno::ENOENT => format!("attachment not found: {path}"),
        Errno::EXDEV | Errno::ELOOP => {
            format!("attachment {path} is outside MAILBEND_ATTACH_DIR or reached through a symlink")
        }
        _ => format!("cannot open attachment {path}: {}", errno.desc()),
    }
}

pub fn not_regular(path: &[u8]) -> String {
    format!("attachment {} is not a regular file", show(path))
}

/// The reason for refusing a file over the remaining byte budget.
pub fn too_large(max: u64, path: &[u8]) -> String {
    format!("attachments would exceed {max} bytes (at {})", show(path))
}

/// A path for an error message.
pub fn show(path: &[u8]) -> String {
    String::from_utf8_lossy(path).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn byte_limit_is_positive_decimal_and_capped() {
        assert_eq!(parse_max(b"1000"), Ok(1000));
        assert_eq!(parse_max(b"999999999999"), Ok(MAX_ATTACHMENT));
        assert!(parse_max(b"\xff").is_err());
        for bad in [
            "",
            "0",
            "-1",
            "+5",
            " 5",
            "5 ",
            "1e3",
            "99999999999999999999999",
        ] {
            assert_eq!(
                parse_max(bad.as_bytes()),
                Err(format!("bad byte limit {bad}"))
            );
        }
    }

    #[test]
    fn send_limit_is_positive_decimal_and_uncapped() {
        assert_eq!(parse_limit(b"3"), Ok(3));
        assert_eq!(parse_limit(b"999999999999"), Ok(999_999_999_999));
        for bad in ["", "0", "-1", "+5", " 5", "1e3"] {
            assert_eq!(
                parse_limit(bad.as_bytes()),
                Err(format!("bad send limit {bad}"))
            );
        }
    }

    #[test]
    fn days_are_yyyy_mm_dd() {
        assert_eq!(parse_day(b"2026-10-06"), Ok(&b"2026-10-06"[..]));
        for bad in [
            "",
            "2026-1-06",
            "2026/10/06",
            "2026-10-06\n",
            "2026-10-0x",
            "12026-10-06",
        ] {
            assert_eq!(parse_day(bad.as_bytes()), Err(format!("bad day {bad}")));
        }
    }

    #[test]
    fn only_lines_of_the_day_count() {
        let counter = b"2026-10-05\n2026-10-06\n2026-10-06\n2026-10-0\nx\n2026-10-06";
        assert_eq!(sends_on(counter, b"2026-10-06"), 3);
        assert_eq!(sends_on(counter, b"2026-10-05"), 1);
        assert_eq!(sends_on(b"", b"2026-10-06"), 0);
    }

    #[test]
    fn a_reservation_fits_only_below_the_limit() {
        assert_eq!(Reservation::new(0, 1), Reservation::Reserved(1));
        assert_eq!(Reservation::new(2, 3), Reservation::Reserved(3));
        assert_eq!(Reservation::new(3, 3), Reservation::Full(3));
        assert_eq!(Reservation::new(5, 3), Reservation::Full(5));
        assert_eq!(Reservation::Reserved(3).to_string(), "ok 3");
        assert_eq!(Reservation::Full(3).to_string(), "full 3");
    }

    #[test]
    fn relative_paths_pass_through() {
        assert_eq!(
            relative_attachment_path(b"att", b"/w/att", b"a/b.txt"),
            Ok(&b"a/b.txt"[..])
        );
        assert_eq!(
            relative_attachment_path(b"att", b"/w/att", b"../x"),
            Ok(&b"../x"[..])
        );
    }

    #[test]
    fn absolute_paths_must_be_inside_the_directory() {
        assert_eq!(
            relative_attachment_path(b"/w/alias/", b"/w/att", b"/w/att/a.txt"),
            Ok(&b"a.txt"[..])
        );
        assert_eq!(
            relative_attachment_path(b"/w/alias//", b"/w/att", b"/w/alias/a.txt"),
            Ok(&b"a.txt"[..])
        );
        let outside = relative_attachment_path(b"/w/att", b"/w/att", b"/w/attic/a.txt");
        assert_eq!(
            outside,
            Err("attachment /w/attic/a.txt is outside MAILBEND_ATTACH_DIR".to_string())
        );
        assert!(relative_attachment_path(b"/w/att", b"/w/att", b"/proc/self/environ").is_err());
    }

    #[test]
    fn empty_paths_name_no_file() {
        let none = Err("attachment path names no file".to_string());
        assert_eq!(relative_attachment_path(b"a", b"/w/a", b""), none);
        assert_eq!(relative_attachment_path(b"/w/a", b"/w/a", b"/w/a/"), none);
    }

    #[test]
    fn containment_respects_component_boundaries() {
        assert!(contains_path(b"/", b"/home/u"));
        assert!(contains_path(b"/home", b"/home/u"));
        assert!(contains_path(b"/home/u", b"/home/u"));
        assert!(!contains_path(b"/home/u", b"/home"));
        assert!(!contains_path(b"/home/us", b"/home/u"));
        assert!(!contains_path(b"/home/u", b"/home/user"));
    }

    #[test]
    fn open_errors_keep_the_helper_messages() {
        assert_eq!(
            directory_open_error(Errno::ENOSYS),
            "attachments need Linux 5.6+ (openat2)"
        );
        assert_eq!(
            directory_open_error(Errno::ELOOP),
            "MAILBEND_ATTACH_DIR changed while it was opened"
        );
        assert_eq!(
            directory_open_error(Errno::EACCES),
            "cannot open MAILBEND_ATTACH_DIR"
        );
        assert_eq!(
            attachment_open_error(Errno::ENOENT, b"a.txt"),
            "attachment not found: a.txt"
        );
        assert!(attachment_open_error(Errno::EXDEV, b"x").contains("outside"));
        assert!(attachment_open_error(Errno::ELOOP, b"x").contains("symlink"));
    }
}
