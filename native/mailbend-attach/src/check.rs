//! Fixed, credential-free platform facts. No diagnostic inode is ever linked.

use std::io::Write;

use mailbend_attach::ATTACHMENTS;
use nix::errno::Errno;

use crate::Refusal;
use crate::dirs::{open_canonical_directory, open_dedicated_directory};
use crate::save::{create_unnamed, open_download_directory};

#[derive(Debug, PartialEq, Eq)]
enum Status {
    Ok,
    Unsupported,
    Refused,
    Unset,
}

impl Status {
    fn token(&self) -> &'static str {
        match self {
            Self::Ok => "ok",
            Self::Unsupported => "unsupported",
            Self::Refused => "refused",
            Self::Unset => "unset",
        }
    }
}

fn openat2_status(result: nix::Result<()>) -> Status {
    match result {
        Ok(()) => Status::Ok,
        Err(_) => Status::Unsupported,
    }
}

fn tmpfile_status(result: nix::Result<()>) -> Status {
    match result {
        Ok(()) => Status::Ok,
        Err(Errno::EOPNOTSUPP | Errno::EISDIR | Errno::ENOSYS) => Status::Unsupported,
        Err(_) => Status::Refused,
    }
}

fn attachment_status(dir: &[u8]) -> Status {
    if dir.is_empty() {
        return Status::Unset;
    }
    match open_dedicated_directory(dir, &ATTACHMENTS) {
        Ok(_) => Status::Ok,
        Err(_) => Status::Refused,
    }
}

fn download_status(attach: &[u8], download: &[u8]) -> Status {
    if download.is_empty() {
        return Status::Unset;
    }
    match open_download_directory(attach, download, b"") {
        Ok(directory) => tmpfile_status(create_unnamed(&directory).map(drop)),
        Err(_) => Status::Refused,
    }
}

pub fn check_platform(attach: &[u8], download: &[u8]) -> Result<(), Refusal> {
    let openat2 = openat2_status(open_canonical_directory(b"/").map(drop));
    let attachments = attachment_status(attach);
    let downloads = download_status(attach, download);
    let arch = match std::env::consts::ARCH {
        "x86_64" => "x86_64",
        "aarch64" => "aarch64",
        _ => "other",
    };
    let mut out = std::io::stdout().lock();
    writeln!(
        out,
        "openat2 {}\nattach_dir {}\ndownload_tmpfile {}\narch {arch}",
        openat2.token(),
        attachments.token(),
        downloads.token(),
    )
    .and_then(|()| out.flush())
    .map_err(|_| "cannot write platform checks".to_string())
}

#[cfg(test)]
mod tests {
    use super::{Status, openat2_status, tmpfile_status};
    use nix::errno::Errno;

    #[test]
    fn absent_or_blocked_openat2_is_unsupported() {
        assert_eq!(openat2_status(Ok(())), Status::Ok);
        for errno in [Errno::ENOSYS, Errno::EPERM, Errno::EACCES] {
            assert_eq!(openat2_status(Err(errno)), Status::Unsupported);
        }
    }

    #[test]
    fn unnamed_files_distinguish_unsupported_from_refused() {
        assert_eq!(tmpfile_status(Ok(())), Status::Ok);
        for errno in [Errno::EOPNOTSUPP, Errno::EISDIR, Errno::ENOSYS] {
            assert_eq!(tmpfile_status(Err(errno)), Status::Unsupported);
        }
        for errno in [Errno::EACCES, Errno::EPERM, Errno::ENOSPC, Errno::EROFS] {
            assert_eq!(tmpfile_status(Err(errno)), Status::Refused);
        }
    }
}
