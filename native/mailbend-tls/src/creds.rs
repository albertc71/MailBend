//! The mail credentials: MAILBEND_EMAIL with MAILBEND_APP_PASSWORD, or the
//! password from MAILBEND_PASSWORD_FILE. Only this helper reads them; they
//! are sent only to the verified server and never written to stdout or
//! stderr. Copies are kept in buffers wiped on drop.

use std::ffi::OsString;
use std::fs::File;
use std::io::{ErrorKind, Read};
use std::os::unix::ffi::OsStringExt;

use mailbend_io::fs::{is_regular, open_at};
use nix::errno::Errno;
use nix::fcntl::{AT_FDCWD, OFlag, ResolveFlag};
use nix::sys::stat::fstat;
use nix::unistd::getuid;
use zeroize::Zeroizing;

use crate::Exit;

/// The longest password file accepted, in bytes (exclusive).
const MAX_PASSWORD_FILE: usize = 1024;

pub struct Credentials {
    pub user: Zeroizing<Vec<u8>>,
    pub pass: Zeroizing<Vec<u8>>,
}

/// The TypeSafe API key must never share a process with the mail password:
/// it belongs in MAILBEND_TYPESAFE_KEY_FILE, read by another process.
pub fn refuse_typesafe_key() -> Result<(), Exit> {
    if std::env::var_os("MAILBEND_TYPESAFE_API_KEY").is_some() {
        return Err(Exit::usage(
            "MAILBEND_TYPESAFE_API_KEY must not be set: the TypeSafe key belongs in \
             MAILBEND_TYPESAFE_KEY_FILE, never next to the mail password",
        ));
    }
    Ok(())
}

pub fn load() -> Result<Credentials, Exit> {
    let user = env_bytes("MAILBEND_EMAIL");
    let mut pass = env_bytes("MAILBEND_APP_PASSWORD");
    let pass_file = env_bytes("MAILBEND_PASSWORD_FILE");
    if user.is_empty() {
        return Err(Exit::usage("MAILBEND_EMAIL is not set"));
    }
    if !pass_file.is_empty() {
        if !pass.is_empty() {
            return Err(Exit::usage(
                "set MAILBEND_APP_PASSWORD or MAILBEND_PASSWORD_FILE, not both",
            ));
        }
        pass = read_password_file(&pass_file)?;
    }
    if pass.is_empty() {
        return Err(Exit::usage(
            "MAILBEND_APP_PASSWORD (or MAILBEND_PASSWORD_FILE) is not set",
        ));
    }
    if !user.iter().all(|b| (0x21..=0x7E).contains(b)) {
        return Err(Exit::usage(
            "MAILBEND_EMAIL must be printable ASCII without spaces",
        ));
    }
    if !pass.iter().all(|b| (0x20..=0x7E).contains(b)) {
        return Err(Exit::usage("the mail password must be printable ASCII"));
    }
    Ok(Credentials { user, pass })
}

/// The variable's bytes, moved (not copied) into a buffer wiped on drop.
fn env_bytes(name: &str) -> Zeroizing<Vec<u8>> {
    Zeroizing::new(
        std::env::var_os(name)
            .map(OsString::into_vec)
            .unwrap_or_default(),
    )
}

/// MAILBEND_PASSWORD_FILE keeps the password out of every environment: an
/// absolute path to a regular file owned by this user, not readable by group
/// or others, holding the password (one trailing LF or CRLF is ignored). It is
/// opened with openat2(RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS), so no
/// component of the path, not just the last, may be a symlink.
fn read_password_file(path: &[u8]) -> Result<Zeroizing<Vec<u8>>, Exit> {
    if path.first() != Some(&b'/') {
        return Err(Exit::usage(
            "MAILBEND_PASSWORD_FILE must be an absolute path",
        ));
    }
    let fd = open_at(
        AT_FDCWD,
        path,
        OFlag::O_RDONLY | OFlag::O_NONBLOCK | OFlag::O_NOCTTY,
        ResolveFlag::RESOLVE_NO_SYMLINKS | ResolveFlag::RESOLVE_NO_MAGICLINKS,
    )
    .map_err(|errno| match errno {
        Errno::ENOSYS => Exit::usage("MAILBEND_PASSWORD_FILE needs Linux 5.6+ (openat2)"),
        Errno::ELOOP => Exit::usage(
            "MAILBEND_PASSWORD_FILE must not be or sit under a symlink: use its real path",
        ),
        _ => Exit::usage("cannot open MAILBEND_PASSWORD_FILE (it must exist)"),
    })?;
    let not_regular = || Exit::usage("MAILBEND_PASSWORD_FILE is not a regular file");
    let stat = fstat(&fd).map_err(|_| not_regular())?;
    if !is_regular(&stat) {
        return Err(not_regular());
    }
    if stat.st_uid != getuid().as_raw() {
        return Err(Exit::usage(
            "MAILBEND_PASSWORD_FILE must be owned by the user running MailBend",
        ));
    }
    if stat.st_mode & 0o077 != 0 {
        return Err(Exit::usage(
            "MAILBEND_PASSWORD_FILE must not be readable by group or others (chmod 600)",
        ));
    }
    let mut file = File::from(fd);
    // Read into a buffer of fixed size: growing it would leave copies.
    let mut buf = Zeroizing::new(vec![0u8; MAX_PASSWORD_FILE]);
    let mut n = 0;
    loop {
        match file.read(&mut buf[n..]) {
            Ok(0) => break,
            Ok(count) => {
                n += count;
                if n == MAX_PASSWORD_FILE {
                    return Err(Exit::usage("MAILBEND_PASSWORD_FILE is too long"));
                }
            }
            Err(e) if e.kind() == ErrorKind::Interrupted => {}
            Err(_) => return Err(Exit::usage("cannot read MAILBEND_PASSWORD_FILE")),
        }
    }
    let content = &buf[..n];
    let content = content.strip_suffix(b"\n").unwrap_or(content);
    let content = content.strip_suffix(b"\r").unwrap_or(content);
    let len = content.len();
    // Truncating keeps the allocation, which is wiped whole on drop.
    buf.truncate(len);
    Ok(buf)
}
