//! Opening files with openat2(2), whose RESOLVE_* flags refuse symlinks in
//! every component of a path rather than only the last.

use std::ffi::OsStr;
use std::os::fd::{AsFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;

use nix::fcntl::{OFlag, OpenHow, ResolveFlag, openat2};
use nix::sys::stat::{FileStat, SFlag};

/// openat2(2) of `path` relative to `dir`, always with O_CLOEXEC.
pub fn open_at(
    dir: impl AsFd,
    path: &[u8],
    flags: OFlag,
    resolve: ResolveFlag,
) -> nix::Result<OwnedFd> {
    let how = OpenHow::new()
        .flags(flags | OFlag::O_CLOEXEC)
        .resolve(resolve);
    openat2(dir, OsStr::from_bytes(path), how)
}

/// Whether `stat` describes a regular file.
pub fn is_regular(stat: &FileStat) -> bool {
    SFlag::from_bits_truncate(stat.st_mode) & SFlag::S_IFMT == SFlag::S_IFREG
}
