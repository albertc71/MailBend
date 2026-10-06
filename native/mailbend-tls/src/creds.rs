//! The mail credentials: MAILBEND_EMAIL with MAILBEND_APP_PASSWORD, or the
//! password from MAILBEND_PASSWORD_FILE. Only this helper reads them; they
//! are sent only to the verified server and never written to stdout or
//! stderr. Copies are kept in buffers wiped on drop.

use std::ffi::OsString;
use std::os::unix::ffi::OsStringExt;

use mailbend_io::secret::read_secret_file;
use zeroize::Zeroizing;

use crate::Exit;

pub struct Credentials {
    pub user: Zeroizing<Vec<u8>>,
    pub pass: Zeroizing<Vec<u8>>,
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
        // The file keeps the password out of every environment.
        pass = read_secret_file(&pass_file, "MAILBEND_PASSWORD_FILE").map_err(Exit::usage)?;
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
