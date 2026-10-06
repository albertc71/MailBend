//! mailbend-attach: MailBend's local file access, safely.
//!
//!   mailbend-attach <dir> <path> <max-bytes>                 > file bytes
//!   mailbend-attach count <state-dir> <limit> <utc-day>      > ok <n> | full <n>
//!   mailbend-attach save <attach-dir> <download-dir> <name> <max-bytes> <path-list>
//!                                                            < file bytes
//!
//! The first form reads one attachment; the second reserves one send in the
//! daily send counter; the third saves one downloaded attachment (`save.rs`).
//! Kept apart from mailbend-tls so the credential-bearing helper never
//! touches files: this program opens no connection, and before anything else
//! it re-executes itself with an empty environment. How files are opened,
//! and which are refused, is specified in native/README.md ("Attachments",
//! "Send counter", "Downloads"); each step is documented where it is done.
//!
//! Exit status: 0 ok (for `count`, also when the limit is reached), 2 refused
//! or unreadable (the reason is on stderr).

use std::ffi::{OsStr, OsString};
use std::fs::{DirBuilder, File, OpenOptions};
use std::io::{ErrorKind, Read, Write};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

use mailbend_attach::{
    ATTACHMENTS, Reservation, SENSITIVE, Setting, attachment_open_error, contains_path,
    directory_open_error, named_component, not_regular, parse_day, parse_limit, parse_max,
    relative_attachment_path, sends_on, show, too_large,
};
use mailbend_io::fs::{create_at, is_regular, open_at};
use mailbend_io::report::report;
use mailbend_io::transcript::encode_bytes;
use nix::errno::Errno;
use nix::fcntl::{AT_FDCWD, AtFlags, Flock, FlockArg, OFlag, ResolveFlag};
use nix::sys::stat::{FileStat, Mode, fstat, fstatat};
use nix::sys::statfs::{PROC_SUPER_MAGIC, SYSFS_MAGIC, fstatfs};
use nix::unistd::{Uid, User};

mod save;

const PROGRAM: &str = "mailbend-attach";
const EX_REFUSED: u8 = 2;
const USAGE: &str = "usage: mailbend-attach <dir> <path> <max-bytes> | \
                     mailbend-attach count <state-dir> <limit> <utc-day> | \
                     mailbend-attach save <attach-dir> <download-dir> <name> <max-bytes> \
                     <path-list>";

type Refusal = String;

fn main() -> ExitCode {
    // A panic must not print its payload, which could hold file names.
    std::panic::set_hook(Box::new(|_| {
        report(PROGRAM, "internal error");
        std::process::exit(i32::from(EX_REFUSED))
    }));
    let args: Vec<OsString> = std::env::args_os().collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(reason) => {
            report(PROGRAM, reason);
            ExitCode::from(EX_REFUSED)
        }
    }
}

fn run(args: &[OsString]) -> Result<(), Refusal> {
    drop_inherited_environment(args)?;
    match args {
        [_, mode, dir, limit, day] if mode == "count" => {
            count_send(dir.as_bytes(), limit.as_bytes(), day.as_bytes())
        }
        [_, mode, attach, download, name, max, paths] if mode == "save" => save::save_download(
            attach.as_bytes(),
            download.as_bytes(),
            name.as_bytes(),
            max.as_bytes(),
            paths.as_bytes(),
        ),
        [_, dir, path, max] => read_attachment(dir.as_bytes(), path.as_bytes(), max.as_bytes()),
        _ => Err(USAGE.to_string()),
    }
}

/// Re-executes this program with an empty environment, unless it already
/// has one. The kernel's copy is checked too: std skips entries without
/// "=", which /proc/self/environ would still show.
fn drop_inherited_environment(args: &[OsString]) -> Result<(), Refusal> {
    let started_with = std::fs::read("/proc/self/environ").unwrap_or_default();
    if std::env::vars_os().next().is_none() && started_with.is_empty() {
        return Ok(());
    }
    let mut command = Command::new("/proc/self/exe");
    if let Some((program, rest)) = args.split_first() {
        command.arg0(program).args(rest);
    }
    let _error = command.env_clear().exec();
    Err("cannot drop the inherited environment".to_string())
}

fn read_attachment(dir: &[u8], path: &[u8], max: &[u8]) -> Result<(), Refusal> {
    let max = parse_max(max)?;
    let (root, directory) = open_dedicated_directory(dir, &ATTACHMENTS)?;
    let relative = relative_attachment_path(dir, root.as_os_str().as_bytes(), path)?;
    let (file, st) = open_attachment(&directory, relative, path)?;
    validate_attachment(&file, &st, path, max)?;
    emit_attachment(file, path, max)
}

/// The directory of `setting`, resolved once with realpath(), opened, and
/// refused unless it is dedicated (`refuse_broad_directory`).
fn open_dedicated_directory(dir: &[u8], setting: &Setting) -> Result<(PathBuf, OwnedFd), Refusal> {
    let root = std::fs::canonicalize(Path::new(OsStr::from_bytes(dir)))
        .map_err(|_| format!("{} does not exist", setting.name))?;
    let bytes = root.as_os_str().as_bytes();
    let directory =
        open_canonical_directory(bytes).map_err(|errno| directory_open_error(errno, setting))?;
    refuse_broad_directory(bytes, &directory, setting)?;
    Ok((root, directory))
}

/// `root` is canonical, so it holds no symlink; opening it with
/// RESOLVE_NO_SYMLINKS fails if a component was swapped for one since
/// realpath() read it.
fn open_canonical_directory(root: &[u8]) -> nix::Result<OwnedFd> {
    open_at(
        AT_FDCWD,
        root,
        OFlag::O_RDONLY | OFlag::O_DIRECTORY,
        ResolveFlag::RESOLVE_NO_SYMLINKS | ResolveFlag::RESOLVE_NO_MAGICLINKS,
    )
}

/// The canonical home directory, from the password database: the
/// environment is already gone.
fn home_directory() -> Option<PathBuf> {
    User::from_uid(Uid::current())
        .ok()
        .flatten()
        .and_then(|user| std::fs::canonicalize(user.dir).ok())
}

/// Every file beneath an attachment directory can be mailed, and a download
/// directory is written to, so neither may be one that holds the user's
/// keys or configuration, nor be or lie inside such a directory.
fn refuse_broad_directory(
    root: &[u8],
    directory: &OwnedFd,
    setting: &Setting,
) -> Result<(), Refusal> {
    let Setting { name, holds } = setting;
    if root == b"/" {
        return Err(format!("{name} must not be /: use a dedicated directory"));
    }
    if home_directory().is_some_and(|home| contains_path(root, home.as_os_str().as_bytes())) {
        return Err(format!(
            "{name} must not be your home directory or contain it: use a dedicated directory"
        ));
    }
    if let Some(sensitive) = named_component(root, &SENSITIVE) {
        return Err(format!(
            "{name} is or lies inside {sensitive}, so it is not a dedicated {holds} directory"
        ));
    }
    for sensitive in SENSITIVE {
        if fstatat(directory, sensitive, AtFlags::AT_SYMLINK_NOFOLLOW).is_ok() {
            return Err(format!(
                "{name} holds {sensitive}, so it is not a dedicated {holds} directory"
            ));
        }
    }
    Ok(())
}

fn open_beneath(
    directory: &OwnedFd,
    relative: &[u8],
    path: &[u8],
    flags: OFlag,
) -> Result<OwnedFd, Refusal> {
    open_at(
        directory,
        relative,
        flags,
        ResolveFlag::RESOLVE_BENEATH
            | ResolveFlag::RESOLVE_NO_SYMLINKS
            | ResolveFlag::RESOLVE_NO_MAGICLINKS,
    )
    .map_err(|errno| attachment_open_error(errno, path))
}

/// Checks the file through an O_PATH descriptor (opening nothing), then
/// reopens that same inode for reading through /proc/self/fd/<probe>, which
/// follows the descriptor rather than walking the path again, so a file
/// swapped in under the name meanwhile is never opened. The inode is compared
/// once more as a backstop, and its status returned. No O_NOFOLLOW on the
/// probe: with O_PATH it would return a final symlink itself instead of
/// letting RESOLVE_NO_SYMLINKS refuse it.
fn open_attachment(
    directory: &OwnedFd,
    relative: &[u8],
    path: &[u8],
) -> Result<(File, FileStat), Refusal> {
    let probe = open_beneath(directory, relative, path, OFlag::O_PATH)?;
    let before = fstat(&probe).map_err(|_| not_regular(path))?;
    if !is_regular(&before) {
        return Err(not_regular(path));
    }
    let self_path = format!("/proc/self/fd/{}", probe.as_raw_fd());
    let file = OpenOptions::new()
        .read(true)
        .custom_flags((OFlag::O_NONBLOCK | OFlag::O_NOCTTY).bits())
        .open(&self_path)
        .map_err(|e| {
            format!(
                "cannot reopen attachment {} through /proc/self/fd: {}",
                show(path),
                os_error_text(&e)
            )
        })?;
    let changed = || format!("attachment {} changed while it was opened", show(path));
    let after = fstat(&file).map_err(|_| changed())?;
    if !same_file(&after, &before) {
        return Err(changed());
    }
    Ok((file, after))
}

/// Whether two status records are of the same file.
fn same_file(a: &FileStat, b: &FileStat) -> bool {
    a.st_dev == b.st_dev && a.st_ino == b.st_ino
}

/// The C library's text for an I/O error, without Rust's "(os error N)".
fn os_error_text(e: &std::io::Error) -> String {
    match e.raw_os_error() {
        Some(code) => Errno::from_raw(code).desc().to_string(),
        None => e.to_string(),
    }
}

/// `st` is the status of the open file, already known to be regular.
fn validate_attachment(file: &File, st: &FileStat, path: &[u8], max: u64) -> Result<(), Refusal> {
    let shown = show(path);
    if st.st_nlink > 1 {
        return Err(format!("attachment {shown} has more than one hard link"));
    }
    let kernel = || format!("attachment {shown} is a kernel file (procfs or sysfs)");
    let fs = fstatfs(file).map_err(|_| kernel())?;
    if fs.filesystem_type() == PROC_SUPER_MAGIC || fs.filesystem_type() == SYSFS_MAGIC {
        return Err(kernel());
    }
    if u64::try_from(st.st_size).unwrap_or(u64::MAX) > max {
        return Err(too_large(max, path));
    }
    Ok(())
}

fn emit_attachment(mut file: File, path: &[u8], max: u64) -> Result<(), Refusal> {
    let mut buf = vec![0u8; 65536];
    let mut encoded = Vec::with_capacity(2 * buf.len());
    let mut total: u64 = 0;
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    let cannot_write = |_| "cannot write the attachment".to_string();
    loop {
        let count = match file.read(&mut buf) {
            Ok(count) => count,
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(_) => return Err(format!("cannot read attachment {}", show(path))),
        };
        if count == 0 {
            break;
        }
        total += count as u64;
        if total > max {
            return Err(too_large(max, path));
        }
        encoded.clear();
        encode_bytes(&buf[..count], &mut encoded);
        out.write_all(&encoded).map_err(cannot_write)?;
    }
    out.flush().map_err(cannot_write)
}

/// Reserves one send for `day` in `<dir>/sends`, which holds one line per
/// send counted: under an exclusive lock, it counts the lines for `day` and,
/// below `limit`, appends one more and prints `ok <n>`; at the limit it
/// appends nothing and prints `full <n>`. The core decides what to do with
/// the answer.
fn count_send(dir: &[u8], limit: &[u8], day: &[u8]) -> Result<(), Refusal> {
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
