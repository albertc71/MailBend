//! The save form: writes one attachment, read from stdin in the core's byte
//! encoding, as a new file in MAILBEND_DOWNLOAD_DIR. Which directories are
//! refused is specified in native/README.md ("Downloads").

use std::ffi::OsStr;
use std::fs::File;
use std::io::{ErrorKind, Read, Write};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;

use mailbend_attach::{
    ATTACHMENTS, DOWNLOADS, STARTUP_HOME, STARTUP_NAMES, Setting, named_component, parse_file_name,
    parse_max, path_entries, show,
};
use mailbend_io::core_bytes::decode_bytes;
use nix::errno::Errno;
use nix::fcntl::{AT_FDCWD, AtFlags, OFlag, open, openat};
use nix::sys::stat::{FileStat, Mode, fstat, stat};
use nix::unistd::linkat;

use crate::Refusal;
use crate::dirs::{home_directory, open_dedicated_directory, os_error_text, same_file};

/// Saves stdin as `name` in the download directory, after checking the
/// directory and before reading any of stdin. `attach` is
/// MAILBEND_ATTACH_DIR ("" when unset) and `paths` the caller's PATH, both
/// passed because the environment is gone.
pub fn save_download(
    attach: &[u8],
    download: &[u8],
    name: &[u8],
    max: &[u8],
    paths: &[u8],
) -> Result<(), Refusal> {
    let max = parse_max(max)?;
    let name = parse_file_name(name)?;
    let (root, directory) = open_dedicated_directory(download, &DOWNLOADS)?;
    let lineage = lineage(&directory, &DOWNLOADS)?;
    refuse_attachment_overlap(attach, &lineage)?;
    refuse_startup_directory(root.as_os_str().as_bytes(), &lineage, paths)?;
    let mut file = create_unnamed(&directory)?;
    write_download(&mut file, max)?;
    link_download(&file, &directory, name)
}

/// A directory and the directories above it, up to `/`, by device and inode.
struct Lineage {
    own: FileStat,
    above: Vec<FileStat>,
}

impl Lineage {
    /// Whether `st` is this directory or one above it.
    fn contains(&self, st: &FileStat) -> bool {
        same_file(&self.own, st) || self.above.iter().any(|d| same_file(d, st))
    }
}

/// The lineage of `directory`. The kernel follows `..` from the open
/// directory, so no symlink or path spelling can make two directories look
/// apart.
fn lineage(directory: &OwnedFd, setting: &Setting) -> Result<Lineage, Refusal> {
    let cannot = |_| format!("cannot walk up from {}", setting.name);
    let up = OFlag::O_PATH | OFlag::O_DIRECTORY | OFlag::O_CLOEXEC;
    let own = fstat(directory).map_err(cannot)?;
    let mut above = Vec::new();
    let mut current = openat(directory, "..", up, Mode::empty()).map_err(cannot)?;
    loop {
        let st = fstat(&current).map_err(cannot)?;
        if same_file(above.last().unwrap_or(&own), &st) {
            return Ok(Lineage { own, above });
        }
        above.push(st);
        current = openat(&current, "..", up, Mode::empty()).map_err(cannot)?;
    }
}

/// A saved file must never become attachable, nor an attachment be
/// replaced, so neither directory may be or contain the other. A set but
/// missing MAILBEND_ATTACH_DIR is refused rather than skipped.
fn refuse_attachment_overlap(attach: &[u8], download: &Lineage) -> Result<(), Refusal> {
    if attach.is_empty() {
        return Ok(());
    }
    let directory = open(
        OsStr::from_bytes(attach),
        OFlag::O_PATH | OFlag::O_DIRECTORY | OFlag::O_CLOEXEC,
        Mode::empty(),
    )
    .map_err(|_| format!("cannot open {}", ATTACHMENTS.name))?;
    let attachments = lineage(&directory, &ATTACHMENTS)?;
    if download.contains(&attachments.own) || attachments.contains(&download.own) {
        return Err(format!(
            "{} and {} must be separate directories, neither inside the other",
            DOWNLOADS.name, ATTACHMENTS.name
        ));
    }
    Ok(())
}

/// Files in some directories may be run: by the desktop session, the init
/// system, or a shell through PATH. A download must land in none of them,
/// and without a home directory the ones under it cannot be checked.
fn refuse_startup_directory(root: &[u8], download: &Lineage, paths: &[u8]) -> Result<(), Refusal> {
    let refuse = |place: String| {
        Err(format!(
            "{} is {place}, whose files may be run: use a dedicated directory",
            DOWNLOADS.name
        ))
    };
    if let Some(name) = named_component(root, &STARTUP_NAMES) {
        return refuse(format!("inside a directory named {name}"));
    }
    let home = home_directory().ok_or_else(|| {
        format!(
            "cannot find your home directory, so {} cannot be checked",
            DOWNLOADS.name
        )
    })?;
    for dir in STARTUP_HOME {
        let startup = stat(&home.join(dir));
        if startup.is_ok_and(|st| download.contains(&st)) {
            return refuse(format!("inside ~/{dir}"));
        }
    }
    for entry in path_entries(paths) {
        if stat(OsStr::from_bytes(entry)).is_ok_and(|st| same_file(&download.own, &st)) {
            return refuse("a directory in PATH".to_string());
        }
    }
    Ok(())
}

/// An unnamed file in the download directory (O_TMPFILE): if this program
/// stops before `link_download`, the kernel drops it and nothing is left.
fn create_unnamed(directory: &OwnedFd) -> Result<File, Refusal> {
    let flags = OFlag::O_TMPFILE | OFlag::O_WRONLY | OFlag::O_CLOEXEC;
    openat(directory, ".", flags, Mode::from_bits_truncate(0o600))
        .map(File::from)
        .map_err(|errno| match errno {
            Errno::EOPNOTSUPP | Errno::EISDIR => format!(
                "{}'s file system cannot hold unnamed files (O_TMPFILE)",
                DOWNLOADS.name
            ),
            _ => format!(
                "cannot create a file in {}: {}",
                DOWNLOADS.name,
                errno.desc()
            ),
        })
}

fn not_bytes() -> Refusal {
    "the attachment did not arrive in the core's byte encoding".to_string()
}

/// Copies stdin into `file`, decoding the core's byte encoding, and refuses
/// once more than `max` bytes arrive; then makes the data durable.
fn write_download(file: &mut File, max: u64) -> Result<(), Refusal> {
    let mut input = vec![0u8; 65536];
    let mut decoded = Vec::with_capacity(input.len());
    let mut pending = 0;
    let mut total: u64 = 0;
    let mut stdin = std::io::stdin().lock();
    let cannot_write =
        |e: std::io::Error| format!("cannot write the download: {}", os_error_text(&e));
    loop {
        let count = match stdin.read(&mut input[pending..]) {
            Ok(count) => count,
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(_) => return Err("cannot read the attachment".to_string()),
        };
        if count == 0 {
            break;
        }
        let available = pending + count;
        decoded.clear();
        let used = decode_bytes(&input[..available], &mut decoded).map_err(|_| not_bytes())?;
        input.copy_within(used..available, 0);
        pending = available - used;
        total += decoded.len() as u64;
        if total > max {
            return Err(format!("the attachment is larger than {max} bytes"));
        }
        file.write_all(&decoded).map_err(cannot_write)?;
    }
    if pending > 0 {
        return Err(not_bytes());
    }
    file.sync_all().map_err(cannot_write)
}

/// Gives the complete file its name. linkat(2) never replaces an existing
/// name, so a file already there is kept.
fn link_download(file: &File, directory: &OwnedFd, name: &[u8]) -> Result<(), Refusal> {
    let unnamed = format!("/proc/self/fd/{}", file.as_raw_fd());
    let flags = AtFlags::AT_SYMLINK_FOLLOW;
    linkat(
        AT_FDCWD,
        unnamed.as_str(),
        directory,
        OsStr::from_bytes(name),
        flags,
    )
    .map_err(|errno| match errno {
        Errno::EEXIST => format!(
            "{} already exists in {}; it was not replaced",
            show(name),
            DOWNLOADS.name
        ),
        _ => format!("cannot name the download {}: {}", show(name), errno.desc()),
    })
}
