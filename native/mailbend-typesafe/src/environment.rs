//! The environment this helper runs in. The Bend core gives every child its
//! whole environment, which may hold the mail password, so before anything
//! else the helper re-executes itself keeping only the settings it needs:
//! the password never shares this process, not even in /proc/self/environ.

use std::ffi::OsString;

use mailbend_io::env::reexec_with;

/// The only variables kept: the key file, the time budget, and the routing
/// and trust settings shared with `mailbend-tls`.
pub const ALLOWED: [&str; 10] = [
    "MAILBEND_TYPESAFE_KEY_FILE",
    "MAILBEND_TIMEOUT_MS",
    "MAILBEND_DOH_URL",
    "MAILBEND_CA_FILE",
    "https_proxy",
    "HTTPS_PROXY",
    "all_proxy",
    "ALL_PROXY",
    "no_proxy",
    "NO_PROXY",
];

/// Re-executes this program with only the allowed settings, unless it
/// already has no others. Returns only when no re-execution is needed; a
/// failed one is an error.
pub fn confine(args: &[OsString]) -> Result<(), String> {
    reexec_with(args, &ALLOWED)
}

#[cfg(test)]
mod tests {
    use super::*;
    use mailbend_io::env::is_kept_entry;

    #[test]
    fn only_listed_settings_are_kept() {
        let is_allowed_entry = |entry: &[u8]| is_kept_entry(entry, &ALLOWED);
        assert!(is_allowed_entry(b"MAILBEND_TYPESAFE_KEY_FILE=/k"));
        assert!(is_allowed_entry(b"https_proxy=http://p:3128"));
        assert!(is_allowed_entry(b"NO_PROXY="));
        assert!(is_allowed_entry(b"all_proxy=http://p:3128"));
        assert!(is_allowed_entry(b"ALL_PROXY=http://p:3128"));
        for refused in [
            &b"MAILBEND_APP_PASSWORD=secret"[..],
            b"MAILBEND_EMAIL=a@b",
            b"MAILBEND_TYPESAFE_API_KEY=k",
            b"http_proxy=http://p",
            b"MAILBEND_TIMEOUT_MS",
            b"MAILBEND_CA_FILEX=/x",
            b"=MAILBEND_CA_FILE",
        ] {
            assert!(
                !is_allowed_entry(refused),
                "{}",
                String::from_utf8_lossy(refused)
            );
        }
    }
}
