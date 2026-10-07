//! The count form: reserves one send in the daily send counter. How the
//! counter is opened is specified in native/README.md ("Send counter").

use std::ffi::OsStr;
use std::fs::{DirBuilder, File};
use std::io::{Read, Write};
use std::os::fd::OwnedFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::DirBuilderExt;
use std::path::Path;

use mailbend_attach::{Reservation, parse_day, parse_limit, sends_on, show};
use mailbend_io::fs::{create_at, is_regular};
use nix::fcntl::{Flock, FlockArg, OFlag, ResolveFlag};
use nix::sys::stat::{Mode, fstat};

use crate::Refusal;
use crate::dirs::{open_canonical_directory, os_error_text};

/// Reserves one send for `day` in `<dir>/sends`, which holds one line per
/// send counted: under an exclusive lock, it counts the lines for `day` and,
/// below `limit`, appends one more and prints `ok <n>`; at the limit it
/// appends nothing and prints `full <n>`. The core decides what to do with
/// the answer.
pub fn count_send(dir: &[u8], limit: &[u8], day: &[u8]) -> Result<(), Refusal> {
    let limit = parse_limit(limit)?;
    let day = parse_day(day)?;
    let directory = open_state_directory(dir)?;
    let counter = open_counter(&directory, dir)?;
    let mut counter = Flock::lock(counter, FlockArg::LockExclusive)
        .map_err(|(_, errno)| counter_error("lock", dir, errno.desc()))?;
    let mut text = Vec::new();
    counter
        .read_to_end(&mut text)
        .map_err(|e| counter_error("read", dir, &os_error_text(&e)))?;
    let reservation = Reservation::new(sends_on(&text, day), limit);
    if let Reservation::Reserved(_) = reservation {
        counter
            .write_all(&[day, b"\n"].concat())
            .and_then(|()| counter.sync_data())
            .map_err(|e| counter_error("write", dir, &os_error_text(&e)))?;
    }
    writeln!(std::io::stdout(), "{reservation}").map_err(|_| "cannot write the count".to_string())
}

fn counter_error(what: &str, dir: &[u8], why: &str) -> Refusal {
    format!("cannot {what} the send counter in {}: {why}", show(dir))
}

fn state_error(what: &str, dir: &[u8], why: &str) -> Refusal {
    format!("cannot {what} the state directory {}: {why}", show(dir))
}

/// The state directory, created with mode 0700 when it is missing. Like
/// MAILBEND_ATTACH_DIR, it is resolved once with realpath() and opened with
/// RESOLVE_NO_SYMLINKS.
fn open_state_directory(dir: &[u8]) -> Result<OwnedFd, Refusal> {
    let path = Path::new(OsStr::from_bytes(dir));
    if !path.is_absolute() {
        return Err(state_error("use", dir, "not an absolute path"));
    }
    DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)
        .map_err(|e| state_error("create", dir, &os_error_text(&e)))?;
    let root =
        std::fs::canonicalize(path).map_err(|e| state_error("resolve", dir, &os_error_text(&e)))?;
    open_canonical_directory(root.as_os_str().as_bytes())
        .map_err(|errno| state_error("open", dir, errno.desc()))
}

/// `sends` beneath the state directory, created with mode 0600 when it is
/// missing; as for an attachment, no symlink or `..` may lead elsewhere,
/// and it must be a regular file.
fn open_counter(directory: &OwnedFd, dir: &[u8]) -> Result<File, Refusal> {
    let counter = create_at(
        directory,
        b"sends",
        OFlag::O_RDWR | OFlag::O_APPEND | OFlag::O_NOCTTY,
        ResolveFlag::RESOLVE_BENEATH
            | ResolveFlag::RESOLVE_NO_SYMLINKS
            | ResolveFlag::RESOLVE_NO_MAGICLINKS,
        Mode::from_bits_truncate(0o600),
    )
    .map_err(|errno| counter_error("open", dir, errno.desc()))?;
    let st = fstat(&counter).map_err(|errno| counter_error("open", dir, errno.desc()))?;
    if !is_regular(&st) {
        return Err(counter_error("use", dir, "not a regular file"));
    }
    Ok(File::from(counter))
}
