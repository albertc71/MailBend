//! Secrets kept out of every environment: a file read with the same rules
//! for each secret (the mail password, the TypeSafe key), and the refusal of
//! a TypeSafe key passed in the environment.

use std::fs::File;
use std::io::{ErrorKind, Read};

use nix::errno::Errno;
use nix::fcntl::{AT_FDCWD, OFlag, ResolveFlag};
use nix::sys::stat::fstat;
use nix::unistd::getuid;
use zeroize::Zeroizing;

use crate::fs::{is_regular, open_at};

/// The longest secret file accepted, in bytes (exclusive).
const MAX_SECRET_FILE: usize = 1024;

/// The TypeSafe key must never share a process with the mail password: it
/// belongs in MAILBEND_TYPESAFE_KEY_FILE, read only by mailbend-typesafe.
pub fn refuse_typesafe_api_key() -> Result<(), String> {
    if std::env::var_os("MAILBEND_TYPESAFE_API_KEY").is_some() {
        return Err(
            "MAILBEND_TYPESAFE_API_KEY must not be set: the TypeSafe key belongs in \
                    MAILBEND_TYPESAFE_KEY_FILE, never next to the mail password"
                .to_string(),
        );
    }
    Ok(())
}

/// The secret in the file `path`, named by the setting `name` in every
/// message: an absolute path to a regular file owned by this user, not
/// readable by group or others, holding the secret (one trailing LF or CRLF
/// is ignored). It is opened with openat2(RESOLVE_NO_SYMLINKS |
/// RESOLVE_NO_MAGICLINKS), so no component of the path, not just the last,
/// may be a symlink. The secret is kept in a buffer wiped on drop.
pub fn read_secret_file(path: &[u8], name: &str) -> Result<Zeroizing<Vec<u8>>, String> {
    if path.first() != Some(&b'/') {
        return Err(format!("{name} must be an absolute path"));
    }
    let fd = open_at(
        AT_FDCWD,
        path,
        OFlag::O_RDONLY | OFlag::O_NONBLOCK | OFlag::O_NOCTTY,
        ResolveFlag::RESOLVE_NO_SYMLINKS | ResolveFlag::RESOLVE_NO_MAGICLINKS,
    )
    .map_err(|errno| match errno {
        Errno::ENOSYS => format!("{name} needs Linux 5.6+ (openat2)"),
        Errno::ELOOP => format!("{name} must not be or sit under a symlink: use its real path"),
        _ => format!("cannot open {name} (it must exist)"),
    })?;
    let not_regular = || format!("{name} is not a regular file");
    let stat = fstat(&fd).map_err(|_| not_regular())?;
    if !is_regular(&stat) {
        return Err(not_regular());
    }
    if stat.st_uid != getuid().as_raw() {
        return Err(format!("{name} must be owned by the user running MailBend"));
    }
    if stat.st_mode & 0o077 != 0 {
        return Err(format!(
            "{name} must not be readable by group or others (chmod 600)"
        ));
    }
    let mut file = File::from(fd);
    // Read into a buffer of fixed size: growing it would leave copies.
    let mut buf = Zeroizing::new(vec![0u8; MAX_SECRET_FILE]);
    let mut n = 0;
    loop {
        match file.read(&mut buf[n..]) {
            Ok(0) => break,
            Ok(count) => {
                n += count;
                if n == MAX_SECRET_FILE {
                    return Err(format!("{name} is too long"));
                }
            }
            Err(e) if e.kind() == ErrorKind::Interrupted => {}
            Err(_) => return Err(format!("cannot read {name}")),
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::{PermissionsExt, symlink};

    fn scratch(tag: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("mailbend-io-secret-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("scratch");
        std::fs::canonicalize(&dir).expect("canonical")
    }

    fn write_secret(path: &std::path::Path, content: &[u8], mode: u32) {
        std::fs::write(path, content).expect("write");
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).expect("chmod");
    }

    #[test]
    fn a_private_file_gives_its_secret_without_the_line_end() {
        let dir = scratch("ok");
        let path = dir.join("key");
        write_secret(&path, b"ts-key-123\r\n", 0o600);
        let secret = read_secret_file(path.as_os_str().as_bytes(), "KEY_FILE").expect("read");
        assert_eq!(secret.as_slice(), b"ts-key-123");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn unsafe_files_are_refused_by_name() {
        let dir = scratch("bad");
        let path = dir.join("key");
        write_secret(&path, b"k", 0o644);
        let bytes = path.as_os_str().as_bytes();
        let refused = |p: &[u8]| read_secret_file(p, "KEY_FILE").map(|_| ()).unwrap_err();
        assert!(refused(bytes).contains("KEY_FILE must not be readable"));
        assert!(refused(b"relative/key").contains("KEY_FILE must be an absolute path"));
        let missing = dir.join("missing");
        assert!(refused(missing.as_os_str().as_bytes()).contains("cannot open KEY_FILE"));
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).expect("chmod");
        let link = dir.join("link");
        symlink(&path, &link).expect("symlink");
        assert!(refused(link.as_os_str().as_bytes()).contains("symlink"));
        assert!(refused(dir.as_os_str().as_bytes()).contains("not a regular file"));
        write_secret(&path, &[b'k'; MAX_SECRET_FILE], 0o600);
        assert!(refused(bytes).contains("too long"));
        let _ = std::fs::remove_dir_all(dir);
    }
}
