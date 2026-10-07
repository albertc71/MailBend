//! What the three forms share: opening a directory setting, refusing one
//! that is not dedicated, and comparing files and reporting OS errors.

use std::ffi::OsStr;
use std::io::ErrorKind;
use std::os::fd::OwnedFd;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

use mailbend_attach::{SENSITIVE, Setting, contains_path, directory_open_error, named_component};
use mailbend_io::fs::open_at;
use nix::errno::Errno;
use nix::fcntl::{AT_FDCWD, AtFlags, OFlag, ResolveFlag};
use nix::sys::stat::{FileStat, fstatat};
use nix::unistd::{Uid, User};

use crate::Refusal;

/// The directory of `setting`, resolved once with realpath(), opened, and
/// refused unless it is dedicated (`refuse_broad_directory`).
pub fn open_dedicated_directory(
    dir: &[u8],
    setting: &Setting,
) -> Result<(PathBuf, OwnedFd), Refusal> {
    let root =
        std::fs::canonicalize(Path::new(OsStr::from_bytes(dir))).map_err(|e| match e.kind() {
            ErrorKind::NotFound => format!("{} does not exist", setting.name),
            _ => format!("cannot resolve {}: {}", setting.name, os_error_text(&e)),
        })?;
    let bytes = root.as_os_str().as_bytes();
    let directory =
        open_canonical_directory(bytes).map_err(|errno| directory_open_error(errno, setting))?;
    refuse_broad_directory(bytes, &directory, setting)?;
    Ok((root, directory))
}

/// `root` is canonical, so it holds no symlink; opening it with
/// RESOLVE_NO_SYMLINKS fails if a component was swapped for one since
/// realpath() read it.
pub fn open_canonical_directory(root: &[u8]) -> nix::Result<OwnedFd> {
    open_at(
        AT_FDCWD,
        root,
        OFlag::O_RDONLY | OFlag::O_DIRECTORY,
        ResolveFlag::RESOLVE_NO_SYMLINKS | ResolveFlag::RESOLVE_NO_MAGICLINKS,
    )
}

/// The canonical home directory, from the password database: the
/// environment is already gone.
pub fn home_directory() -> Option<PathBuf> {
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

/// Whether two status records are of the same file.
pub fn same_file(a: &FileStat, b: &FileStat) -> bool {
    a.st_dev == b.st_dev && a.st_ino == b.st_ino
}

/// The C library's text for an I/O error, without Rust's "(os error N)".
pub fn os_error_text(e: &std::io::Error) -> String {
    match e.raw_os_error() {
        Some(code) => Errno::from_raw(code).desc().to_string(),
        None => e.to_string(),
    }
}
