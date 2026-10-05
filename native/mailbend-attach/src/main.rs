//! mailbend-attach: reads one attachment for MailBend, safely.
//!
//!   mailbend-attach <dir> <path> <max-bytes>   > file bytes
//!
//! Kept apart from mailbend-tls so the credential-bearing helper never reads
//! files: this program opens no connection, and before anything else it
//! re-executes itself with an empty environment. (Clearing the environment
//! is not enough: /proc/self/environ shows the environment the process
//! started with, which may hold the app password.) Files on procfs or sysfs
//! are refused as well.
//!
//! <path> is relative to <dir>, or absolute inside it. <dir> is resolved once
//! with realpath() and opened by that canonical path with
//! RESOLVE_NO_SYMLINKS, so a component swapped for a symlink afterwards is
//! refused. The file is opened beneath it with openat2(RESOLVE_BENEATH |
//! RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS), so no symlink or ".." leads
//! outside, and only a regular file of at most <max-bytes> (never more than
//! 25 MiB) is read, checked on the opened descriptor itself. The file's type
//! is checked first on an O_PATH descriptor, so a device or FIFO found there
//! is not opened. That same inode is then reopened for reading through
//! /proc/self/fd, not by walking the path again, so a file a concurrent local
//! writer substitutes under the name is never opened. A file with more than
//! one hard link is refused (another name for it may live outside <dir>).
//!
//! <dir> must be a dedicated directory: "/", the user's home directory or any
//! directory containing it, and a directory holding .ssh, .gnupg, .aws,
//! .config or .git are refused, since every file inside <dir> can be mailed.
//!
//! The mode is chosen by the argument count alone, so a relative <dir> of any
//! name keeps working: three arguments is always the read form.
//!
//! stdout: the file's bytes, each byte 0x80-0xFF written as the UTF-8
//! encoding of U+0080-U+00FF (the same encoding as mailbend-tls), so the Bend
//! side reads one character per byte.
//!
//! Exit status: 0 ok, 2 refused or unreadable (the reason is on stderr).

use std::ffi::OsString;
use std::fs::{File, OpenOptions};
use std::io::{ErrorKind, Read, Write};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

use mailbend_attach::{
    SENSITIVE, attachment_open_error, contains_path, directory_open_error, encode, parse_max,
    relative_attachment_path, show,
};
use nix::fcntl::{AT_FDCWD, OFlag, OpenHow, ResolveFlag, openat2};
use nix::sys::stat::{FileStat, SFlag, fstat, fstatat};
use nix::sys::statfs::{PROC_SUPER_MAGIC, SYSFS_MAGIC, fstatfs};
use nix::unistd::{Uid, User};

const EX_REFUSED: u8 = 2;

type Refusal = String;

fn main() -> ExitCode {
    // A panic must not print its payload, which could hold file names.
    std::panic::set_hook(Box::new(|_| {
        eprintln!("mailbend-attach: internal error");
        std::process::exit(i32::from(EX_REFUSED))
    }));
    let args: Vec<OsString> = std::env::args_os().collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(reason) => {
            eprintln!("mailbend-attach: {reason}");
            ExitCode::from(EX_REFUSED)
        }
    }
}

fn run(args: &[OsString]) -> Result<(), Refusal> {
    drop_inherited_environment(args)?;
    match args {
        [_, dir, path, max] => read_attachment(dir.as_bytes(), path.as_bytes(), max),
        _ => Err("usage: mailbend-attach <dir> <path> <max-bytes>".to_string()),
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

fn read_attachment(dir: &[u8], path: &[u8], max: &OsString) -> Result<(), Refusal> {
    let max = parse_max(&max.to_string_lossy())?;
    let root = std::fs::canonicalize(Path::new(std::ffi::OsStr::from_bytes(dir)))
        .map_err(|_| "MAILBEND_ATTACH_DIR does not exist".to_string())?;
    let root = root.as_os_str().as_bytes();
    let relative = relative_attachment_path(dir, root, path)?;
    let directory = open_attachment_directory(root)?;
    refuse_broad_directory(root, &directory)?;
    let file = open_attachment(&directory, relative, path)?;
    validate_attachment(&file, path, max)?;
    emit_attachment(file, path, max)
}

fn open2(
    dirfd: impl std::os::fd::AsFd,
    path: &[u8],
    flags: OFlag,
    resolve: ResolveFlag,
) -> nix::Result<OwnedFd> {
    let how = OpenHow::new()
        .flags(flags | OFlag::O_CLOEXEC)
        .resolve(resolve);
    openat2(dirfd, std::ffi::OsStr::from_bytes(path), how)
}

/// `root` is canonical, so it holds no symlink; opening it with
/// RESOLVE_NO_SYMLINKS fails if a component was swapped for one since
/// realpath() read it.
fn open_attachment_directory(root: &[u8]) -> Result<OwnedFd, Refusal> {
    open2(
        AT_FDCWD,
        root,
        OFlag::O_RDONLY | OFlag::O_DIRECTORY,
        ResolveFlag::RESOLVE_NO_SYMLINKS | ResolveFlag::RESOLVE_NO_MAGICLINKS,
    )
    .map_err(directory_open_error)
}

/// Every file beneath the directory can be mailed, so it must not be one that
/// holds the user's keys or configuration. The home directory comes from the
/// password database: the environment is already gone.
fn refuse_broad_directory(root: &[u8], directory: &OwnedFd) -> Result<(), Refusal> {
    if root == b"/" {
        return Err("MAILBEND_ATTACH_DIR must not be /: use a dedicated directory".to_string());
    }
    let home: Option<PathBuf> = User::from_uid(Uid::current())
        .ok()
        .flatten()
        .and_then(|user| std::fs::canonicalize(user.dir).ok());
    if let Some(home) = home {
        if contains_path(root, home.as_os_str().as_bytes()) {
            return Err("MAILBEND_ATTACH_DIR must not be your home directory or contain it: use a dedicated directory".to_string());
        }
    }
    for name in SENSITIVE {
        if fstatat(directory, name, nix::fcntl::AtFlags::AT_SYMLINK_NOFOLLOW).is_ok() {
            return Err(format!(
                "MAILBEND_ATTACH_DIR holds {name}, so it is not a dedicated attachment directory"
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
    open2(
        directory,
        relative,
        flags,
        ResolveFlag::RESOLVE_BENEATH
            | ResolveFlag::RESOLVE_NO_SYMLINKS
            | ResolveFlag::RESOLVE_NO_MAGICLINKS,
    )
    .map_err(|errno| attachment_open_error(errno, path))
}

fn is_regular(st: &FileStat) -> bool {
    SFlag::from_bits_truncate(st.st_mode) & SFlag::S_IFMT == SFlag::S_IFREG
}

/// Checks the file through an O_PATH descriptor (opening nothing), then
/// reopens that same inode for reading through /proc/self/fd/<probe>, which
/// follows the descriptor rather than walking the path again, so a file
/// swapped in under the name meanwhile is never opened. The inode is compared
/// once more as a backstop. No O_NOFOLLOW on the probe: with O_PATH it would
/// return a final symlink itself instead of letting RESOLVE_NO_SYMLINKS
/// refuse it.
fn open_attachment(directory: &OwnedFd, relative: &[u8], path: &[u8]) -> Result<File, Refusal> {
    let probe = open_beneath(directory, relative, path, OFlag::O_PATH)?;
    let not_regular = || format!("attachment {} is not a regular file", show(path));
    let before = fstat(&probe).map_err(|_| not_regular())?;
    if !is_regular(&before) {
        return Err(not_regular());
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
    if after.st_dev != before.st_dev || after.st_ino != before.st_ino {
        return Err(changed());
    }
    Ok(file)
}

/// The C library's text for an I/O error, without Rust's "(os error N)".
fn os_error_text(e: &std::io::Error) -> String {
    match e.raw_os_error() {
        Some(code) => nix::errno::Errno::from_raw(code).desc().to_string(),
        None => e.to_string(),
    }
}

fn validate_attachment(file: &File, path: &[u8], max: u64) -> Result<(), Refusal> {
    let shown = show(path);
    let st = fstat(file).map_err(|_| format!("attachment {shown} is not a regular file"))?;
    if !is_regular(&st) {
        return Err(format!("attachment {shown} is not a regular file"));
    }
    if st.st_nlink > 1 {
        return Err(format!("attachment {shown} has more than one hard link"));
    }
    let kernel = || format!("attachment {shown} is a kernel file (procfs or sysfs)");
    let fs = fstatfs(file).map_err(|_| kernel())?;
    if fs.filesystem_type() == PROC_SUPER_MAGIC || fs.filesystem_type() == SYSFS_MAGIC {
        return Err(kernel());
    }
    if u64::try_from(st.st_size).unwrap_or(u64::MAX) > max {
        return Err(format!("attachments would exceed {max} bytes (at {shown})"));
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
            return Err(format!(
                "attachments would exceed {max} bytes (at {})",
                show(path)
            ));
        }
        encoded.clear();
        encode(&buf[..count], &mut encoded);
        out.write_all(&encoded).map_err(cannot_write)?;
    }
    out.flush().map_err(cannot_write)
}
