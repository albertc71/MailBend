//! The read form: writes one attachment from MAILBEND_ATTACH_DIR to stdout
//! in the core's byte encoding. Which files are refused is specified in
//! native/README.md ("Attachments").

use std::fs::{File, OpenOptions};
use std::io::{ErrorKind, Read, Write};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::OpenOptionsExt;

use mailbend_attach::{
    ATTACHMENTS, attachment_open_error, not_regular, parse_max, relative_attachment_path, show,
    too_large,
};
use mailbend_io::core_bytes::encode_bytes;
use mailbend_io::fs::{is_regular, open_at};
use nix::fcntl::{OFlag, ResolveFlag};
use nix::sys::stat::{FileStat, fstat};
use nix::sys::statfs::{PROC_SUPER_MAGIC, SYSFS_MAGIC, fstatfs};

use crate::Refusal;
use crate::dirs::{open_dedicated_directory, os_error_text, same_file};

pub fn read_attachment(dir: &[u8], path: &[u8], max: &[u8]) -> Result<(), Refusal> {
    let max = parse_max(max)?;
    let (root, directory) = open_dedicated_directory(dir, &ATTACHMENTS)?;
    let relative = relative_attachment_path(dir, root.as_os_str().as_bytes(), path)?;
    let (file, st) = open_attachment(&directory, relative, path)?;
    validate_attachment(&file, &st, path, max)?;
    emit_attachment(file, path, max)
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
